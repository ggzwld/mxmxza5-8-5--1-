create or replace function public.apply_books_invoice_tax()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
declare
  selected_rate numeric;
  selected_booking public.hotel_bookings%rowtype;
begin
  if new.invoice_number like 'HOTEL-%' then
    select * into selected_booking from public.hotel_bookings
     where 'HOTEL-' || confirmation_number = new.invoice_number;
    if found then
      new.tax_rate_id := selected_booking.vat_rate_id;
      new.tax_rate_percentage := selected_booking.vat_rate_percentage;
      new.tax_amount := selected_booking.vat_amount;
      return new;
    end if;
  end if;
  if new.tax_rate_id is not null then
    select rate_percentage into selected_rate
      from public.books_tax_rates
     where id = new.tax_rate_id
       and organization_id = new.organization_id
       and (tax_scope <> 'invoice' or confirmed_at is not null)
       and is_active
       and new.issue_date >= effective_from
       and (effective_to is null or new.issue_date <= effective_to);
    if selected_rate is null then raise exception 'Selected tax rate is not active for this invoice date'; end if;
    new.tax_rate_percentage := selected_rate;
    if new.invoice_number like 'HOTEL-%' then
      if public.checkout_currency_minor_units(new.currency_code) is null then
        raise exception 'Hotel invoice currency is not supported';
      end if;
      new.tax_amount := round(
        new.subtotal * selected_rate / 100,
        public.checkout_currency_minor_units(new.currency_code)
      );
    elsif new.invoice_number like 'TASK-%' then
      -- Worker task VAT is the balance of the approved amount, so it is validated rather than recalculated.
      if abs(new.tax_amount - new.subtotal * selected_rate / 100)
         > (1 + selected_rate / 100) * power(10::numeric, -public.checkout_currency_minor_units(new.currency_code)) / 2 then
        raise exception 'Task invoice VAT does not match its subtotal and rate';
      end if;
    else
      new.tax_amount := round(new.subtotal * selected_rate / 100, 4);
    end if;
  else
    new.tax_rate_percentage := 0;
    new.tax_amount := 0;
  end if;

  if new.invoice_number like 'HOTEL-%' then
    select * into selected_booking
      from public.hotel_bookings
     where 'HOTEL-' || confirmation_number = new.invoice_number;
    if found and (
      new.currency_code::text <> selected_booking.currency_code::text
      or new.subtotal <> selected_booking.taxable_subtotal
      or new.tax_amount <> selected_booking.vat_amount
      or new.other_charges <> selected_booking.lht_amount
    ) then
      raise exception 'Hotel invoice totals do not match the verified reservation';
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.create_worker_task_invoice(target_task_id uuid, manual_fx_rate numeric)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  task_row public.tasks%rowtype;
  invoice_row public.books_invoices%rowtype;
  existing_link public.worker_task_invoices%rowtype;
  worker_user_id uuid;
  hotel_name text;
  hotel_currency char(3);
  worker_organization_id uuid;
  worker_currency char(3);
  worker_vat_registered boolean;
  worker_tax_country text;
  fx_row record;
  applied_rate numeric;
  applied_source text;
  applied_fetched_at timestamptz;
  gross_amount numeric;
  vat_rate_id uuid;
  vat_rate_percentage numeric := 0;
  subtotal_amount numeric;
  hotel_tax numeric := 0;
  customer_id uuid;
  journal_id uuid;
  receivable_id uuid;
  revenue_id uuid;
  vat_payable_id uuid;
begin
  select * into task_row from public.tasks where id = target_task_id for update;
  if not found then raise exception 'Task not found'; end if;

  select * into existing_link from public.worker_task_invoices where task_id = target_task_id;
  if found then return existing_link.invoice_id; end if;

  if task_row.organization_id is null or task_row.assigned_to is null
     or coalesce(task_row.final_amount, 0) <= 0 then
    return null;
  end if;
  if manual_fx_rate is not null and manual_fx_rate <= 0 then
    raise exception 'Manual FX rate must be greater than zero';
  end if;

  select profile.user_id into worker_user_id
    from public.user_profiles profile where profile.id = task_row.assigned_to;
  if worker_user_id is null then raise exception 'Assigned worker profile not found'; end if;

  select organization.name, organization.base_currency
    into hotel_name, hotel_currency
    from public.books_organizations organization where organization.id = task_row.organization_id;

  worker_organization_id := public.ensure_worker_books_organization(worker_user_id, hotel_currency);
  select organization.base_currency, organization.vat_registered, organization.tax_country_code
    into worker_currency, worker_vat_registered, worker_tax_country
    from public.books_organizations organization where organization.id = worker_organization_id;

  select * into fx_row from public.books_task_payment_fx_rate(hotel_currency, worker_currency);
  if fx_row.rate_status in ('same_currency', 'stored') then
    applied_rate := fx_row.fx_rate;
    applied_source := fx_row.rate_status;
    applied_fetched_at := fx_row.rate_fetched_at;
  elsif manual_fx_rate is not null then
    applied_rate := manual_fx_rate;
    applied_source := 'manual';
  elsif fx_row.rate_status = 'stale' then
    raise exception 'FX_RATE_STALE: The stored % to % rate is older than 7 days. Enter a manual rate to continue.', hotel_currency, worker_currency;
  else
    raise exception 'FX_RATE_MISSING: No stored % to % rate exists. Enter a manual rate to continue.', hotel_currency, worker_currency;
  end if;

  gross_amount := round(task_row.final_amount * applied_rate, public.checkout_currency_minor_units(worker_currency));
  if gross_amount <= 0 then raise exception 'Converted task amount is zero'; end if;

  if worker_vat_registered then
    select rate.id, rate.rate_percentage into vat_rate_id, vat_rate_percentage
      from public.books_tax_rates rate
     where rate.organization_id = worker_organization_id
       and rate.country_code = worker_tax_country
       and rate.tax_scope = 'invoice'
       and rate.is_active
       and rate.confirmed_at is not null
       and rate.effective_from <= current_date
       and (rate.effective_to is null or rate.effective_to >= current_date)
     order by rate.effective_from desc, rate.confirmed_at desc
     limit 1;
    if vat_rate_id is null then
      raise exception 'Confirm a VAT rate in your Books tax settings before this task can be approved';
    end if;
    subtotal_amount := round(
      gross_amount / (1 + vat_rate_percentage / 100),
      public.checkout_currency_minor_units(worker_currency)
    );
    hotel_tax := task_row.final_amount - round(
      task_row.final_amount / (1 + vat_rate_percentage / 100),
      public.checkout_currency_minor_units(hotel_currency)
    );
  else
    subtotal_amount := gross_amount;
  end if;

  select contact.id into customer_id from public.books_contacts contact
   where contact.organization_id = worker_organization_id
     and lower(contact.name) = lower(hotel_name)
     and contact.type in ('customer', 'both')
   order by contact.created_at
   limit 1;
  if customer_id is null then
    insert into public.books_contacts (organization_id, name, type)
    values (worker_organization_id, hotel_name, 'customer')
    returning id into customer_id;
  end if;

  insert into public.books_invoices (
    organization_id, contact_id, invoice_number, issue_date, due_date, currency_code,
    subtotal, tax_amount, tax_rate_id, status, notes
  ) values (
    worker_organization_id, customer_id, 'TASK-' || task_row.id::text, current_date, current_date, worker_currency,
    subtotal_amount, gross_amount - subtotal_amount, vat_rate_id, 'sent', 'Approved task: ' || task_row.title
  )
  returning * into invoice_row;

  insert into public.worker_task_invoices (
    task_id, invoice_id, worker_organization_id, hotel_organization_id,
    hotel_currency_code, hotel_amount, hotel_tax_amount,
    worker_currency_code, fx_rate, fx_rate_source, fx_rate_fetched_at
  ) values (
    task_row.id, invoice_row.id, worker_organization_id, task_row.organization_id,
    hotel_currency, task_row.final_amount, hotel_tax,
    worker_currency, applied_rate, applied_source, applied_fetched_at
  );

  select account.id into receivable_id from public.books_accounts account
   where account.organization_id = worker_organization_id and account.code = '1100';
  select account.id into revenue_id from public.books_accounts account
   where account.organization_id = worker_organization_id and account.code = '4000';
  select account.id into vat_payable_id from public.books_accounts account
   where account.organization_id = worker_organization_id and account.code = '2100';
  if receivable_id is null or revenue_id is null or (invoice_row.tax_amount > 0 and vat_payable_id is null) then
    raise exception 'Required worker Books account is missing';
  end if;

  insert into public.books_journal_transactions (organization_id, source_type, source_id, transaction_date, description, created_by)
  values (worker_organization_id, 'worker_task_invoice', invoice_row.id, current_date, 'Task invoice ' || invoice_row.invoice_number, worker_user_id)
  returning id into journal_id;

  insert into public.books_journal_lines (transaction_id, account_id, debit, credit, currency_code, exchange_rate)
  values (journal_id, receivable_id, invoice_row.total, 0, worker_currency, 1),
         (journal_id, revenue_id, 0, invoice_row.subtotal, worker_currency, 1);
  if invoice_row.tax_amount > 0 then
    insert into public.books_journal_lines (transaction_id, account_id, debit, credit, currency_code, exchange_rate)
    values (journal_id, vat_payable_id, 0, invoice_row.tax_amount, worker_currency, 1);
  end if;

  return invoice_row.id;
end;
$$;
