drop table if exists shipping_datamart;
drop table if exists shipping_info;
drop table if exists shipping_country_rates;
drop table if exists shipping_agreement;
drop table if exists shipping_transfer;
drop table if exists shipping_status;


create table shipping_country_rates
(
    shipping_country_id        serial primary key,
    shipping_country           text,
    shipping_country_base_rate numeric(14, 3)
);

insert into shipping_country_rates (shipping_country, shipping_country_base_rate)
select distinct shipping_country, shipping_country_base_rate
from shipping;

create table shipping_agreement
(
    agreementid          bigint primary key,
    agreement_number     text,
    agreement_rate       numeric(14, 2),
    agreement_commission numeric(14, 2)
);

insert into shipping_agreement
select vad[1]::bigint         as agreementid,
       vad[2]                 as agreement_number,
       vad[3]::numeric(14, 2) as agreement_rate,
       vad[4]::numeric(14, 2) as agreement_commission
from (select distinct regexp_split_to_array(vendor_agreement_description, ':') as vad from shipping) tmp;


create table shipping_transfer
(
    transfer_type_id       serial primary key,
    transfer_type          text check ( transfer_type in ('1p', '3p') ),
    transfer_model         text check ( transfer_model in ('ship', 'multiplie', 'train', 'airplane') ),
    shipping_transfer_rate numeric(14, 3)
);


insert into shipping_transfer (transfer_type, transfer_model, shipping_transfer_rate)
select std[1] as transfer_type,
       std[2] as transfer_model,
       shipping_transfer_rate
from (select distinct regexp_split_to_array(shipping_transfer_description, ':') as std, shipping_transfer_rate
      from shipping) as tmp;


create table shipping_info
(
    shippingid             bigint primary key,
    vendorid               bigint,
    payment_amount         numeric(14, 2),
    shipping_plan_datetime timestamp,
    agreementid            bigint references shipping_agreement (agreementid) on update cascade,
    shipping_country_id    bigint references shipping_country_rates (shipping_country_id) on update cascade,
    transfer_type_id       bigint references shipping_transfer (transfer_type_id) on update cascade
);


insert into shipping_info
select distinct shippingid,
                vendorid,
--                 transfer_type,
--                 transfer_model,
                payment_amount,
                shipping_plan_datetime,
                (regexp_split_to_array(vendor_agreement_description, ':'))[1]::bigint as agreementid,
                shipping_country_id,
                transfer_type_id
from shipping s
         join shipping_country_rates scr on s.shipping_country_base_rate = scr.shipping_country_base_rate
         join shipping_transfer st
              on (regexp_split_to_array(s.shipping_transfer_description, ':'))[1] = st.transfer_type
                  and (regexp_split_to_array(s.shipping_transfer_description, ':'))[2] = st.transfer_model;
-- order by shippingid, vendorid, transfer_type, transfer_model, payment_amount, shipping_plan_datetime, agreementid,
--          shipping_country_id, transfer_type_id
-- limit 10;


create table shipping_status
(
    shippingid                   bigint,
    status                       text,
    state                        text,
    shipping_start_fact_datetime timestamp,
    shipping_end_fact_datetime   timestamp
);

insert into shipping_status
with tmp as (select shippingid,
                    max(case when state = 'booked' then state_datetime end)   as shipping_start_fact_datetime,
                    max(case when state = 'recieved' then state_datetime end) as shipping_end_fact_datetime,
                    max(state_datetime)                                       as max_state_datetime
             from shipping
             group by shippingid)
select tmp.shippingid, status, state, tmp.shipping_start_fact_datetime, tmp.shipping_end_fact_datetime
from tmp
         join shipping s on tmp.shippingid = s.shippingid
where max_state_datetime = s.state_datetime
order by shippingid, state_datetime;

create table shipping_datamart
(
    shippingid            bigint,
    vendorid              bigint,
    transfer_type         text,
    full_day_at_shipping  bigint,
    is_delay              bigint,
    is_shipping_finish    bigint,
    delay_day_at_shipping bigint,
    payment_amount numeric(14, 3),
    vat                   numeric(14, 3),
    profit                numeric(14, 2)
);

insert into shipping_datamart
with data_mart as (select s.shippingid,
                          s.vendorid,
                          (regexp_split_to_array(shipping_transfer_description, ':'))[1]                 as transfer_type,
                          date_part('day',
                                    age(ss.shipping_end_fact_datetime, ss.shipping_start_fact_datetime)) as full_day_at_shipping,
                          case
                              when shipping_end_fact_datetime > s.shipping_plan_datetime then 1
                              else 0 end                                                                 as is_delay,
                          case when s.status = 'finished' then 1 else 0 end                              as is_shipping_finish,
                          case
                              when ss.shipping_end_fact_datetime > shipping_plan_datetime
                                  then extract(days from (shipping_end_fact_datetime - shipping_plan_datetime))
                              else 0 end                                                                 as delay_day_at_shipping,
                          s.payment_amount,
                          payment_amount *
                          (shipping_country_base_rate +
                           (regexp_split_to_array(vendor_agreement_description, ':'))[3]::numeric(14, 3) +
                           shipping_transfer_rate)                                                       as vat,
                          payment_amount *
                          (regexp_split_to_array(vendor_agreement_description, ':'))[4]::numeric(14, 2)  as profit,
                          state_datetime
                   from shipping s
                            join public.shipping_status ss on s.shippingid = ss.shippingid
                   order by shippingid, is_shipping_finish),

     max_dates as (select shippingid, max(state_datetime) as max_state_datetime
                   from shipping
                   group by shippingid)
select dm.shippingid,
       vendorid,
       transfer_type,
       full_day_at_shipping,
       is_delay,
       is_shipping_finish,
       delay_day_at_shipping,
       payment_amount,
       vat,
       profit
from max_dates
         join data_mart dm on dm.shippingid = max_dates.shippingid
where max_state_datetime = dm.state_datetime
order by shippingid;
