# 1.

<hr>

Нужно убрать дубликаты так как они дублируются и тут объект
`shipping_country` как-бы сущность с свойством
`shipping_country_base_rate` то есть с комиссией
и мы вынесли его в отдельную модель. При этом нужно все таки
оставить 3 цифры после запятой как есть на исходной таблице
на всякий случай даже если во всех комиссиях кажется последняя 0
лишней

```postgresql
create table shipping_country_rates
(
    shipping_countr_id         serial primary key,
    shipping_country           text,
    shipping_country_base_rate numeric(14, 3)
);

insert into shipping_country_rates (shipping_country, shipping_country_base_rate)
select distinct shipping_country, shipping_country_base_rate
from shipping;
```

| shipping\_countr\_id | shipping\_country | shipping\_country\_base\_rate |
| :--- | :--- | :--- |
| 1 | usa | 0.020 |
| 2 | norway | 0.040 |
| 3 | germany | 0.010 |
| 4 | russia | 0.030 |

# 2.

<hr>

```postgresql
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
```

Ниже выборка из `shipping_agreement`, их суммарно 60.

| agreementid | agreement\_number | agreement\_rate | agreement\_commission |
| :--- | :--- | :--- | :--- |
| 32 | vspn-1730 | 0.12 | 0.02 |
| 47 | vspn-3444 | 0.07 | 0.03 |
| 19 | vspn-9037 | 0.07 | 0.02 |
| 59 | vspn-7141 | 0.07 | 0.01 |

# 3.

<hr>

Тут я решил добавить проверку на целостность чтоб не попали какие-то
неожидаемые категории. Конечно тут имеется ввиду что
`transfer_type` и `transfer_model` не так часто меняется.

```postgresql
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
```

| transfer\_type | transfer\_model | shipping\_transfer\_rate |
| :--- | :--- | :--- |
| 3p | ship | 0.025 |
| 1p | multiplie | 0.050 |
| 3p | train | 0.020 |
| 3p | airplane | 0.035 |
| 1p | ship | 0.030 |
| 1p | train | 0.025 |
| 1p | airplane | 0.040 |
| 3p | multiplie | 0.045 |

# 4.

Нужно отметить что лучше сразу сделать `on update cascade`.
А то если вносят изменения СУДБ будет ругаться, вместо того чтоб
стянуть измененное значение этой колонки.

```postgresql
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
```

Нас попросили джоинить таблицы чтоб достать их
суррогатные(кроме `shipping_agreement`) ключи
для нашей `shipping_info` таблицы, но придется нам джоинить их
как-то не естественными путями.

- так как из таблицы `shipping_agreement` на нужен только его первичный ключ
  то есть его колонка `agreementid` джоинить ничего не надо.
  Можно добыть его из колонки `vendor_agreement_description`
- Для `shipping_country_id` пришлось джоинить из через текстовое
  поле `shipping_country`, я конечно не сторонник такой практики, хотелось бы чтоб вынесли
  его в отдельную таблицу с каким-то `countr_сode`ом.
  Поначалу хотел через `shipping_country_base_rate`, думал что по numeric
  будет работать быстрее, но
-
    - `numeric` в пострес underthehood хранятcя `string`ами,
      значит они равнозначны по перформенсу текстовым типам
-
    - `shipping_country_base_rate` это какое-то не статичное(процентное) значение
- Тут тоже будем джойнить по строковым полям `transfer_rate`
  и `transfer_model` соблюдаю вышеуказанную логику

Нужно обратить внимание на distinct и left join, чтоб исключить те данные где
поменялся только status/state, но все остальное дублируется так
как тут логгинг механизм. У нас тут join и left join
не скажется на результат выборки потому что null значений в таблице нет.
Но так как в DDL `shipping` нет ни одного not null ограничения
решил все таки проверить наличие null в любой колонке выполнив запрос

```postgresql
select *
from shipping
where shippingid is null
   or saleid is null
   or orderid is null
   or clientid is null
   or payment_amount is null
   or state_datetime is null
   or productid is null
   or description is null
   or vendorid is null
   or namecategory is null
   or base_country is null
   or status is null
   or state is null
   or shipping_plan_datetime is null
   or hours_to_plan_shipping is null
   or shipping_transfer_description is null
   or shipping_transfer_rate is null
   or shipping_country is null
   or shipping_country_base_rate is null
   or vendor_agreement_description is null
```

Но все равно в аналитических лучше целях сделать left join

```postgresql
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
         left join shipping_country_rates scr on s.shipping_country_base_rate = scr.shipping_country_base_rate
         left join shipping_transfer st
                   on (regexp_split_to_array(s.shipping_transfer_description, ':'))[1] = st.transfer_type
                       and (regexp_split_to_array(s.shipping_transfer_description, ':'))[2] = st.transfer_model;
-- order by shippingid, vendorid, transfer_type, transfer_model, payment_amount, shipping_plan_datetime, agreementid,
--          shipping_country_id, transfer_type_id
-- limit 10
```

| shippingid | vendorid | payment\_amount | shipping\_plan\_datetime | agreementid | shipping\_country\_id | transfer\_type\_id |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| 1 | 1 | 6.06 | 2021-09-15 16:43:42.434645 | 0 | 4 | 6 |
| 2 | 1 | 21.93 | 2021-12-12 10:49:50.468177 | 1 | 1 | 6 |
| 3 | 1 | 3.10 | 2021-10-27 10:33:16.659000 | 2 | 2 | 7 |
| 4 | 3 | 8.57 | 2021-09-21 10:14:30.148733 | 3 | 3 | 6 |
| 5 | 3 | 1.50 | 2022-01-02 21:21:08.844221 | 3 | 2 | 6 |
| 6 | 1 | 3.73 | 2021-11-01 07:05:50.404000 | 0 | 3 | 7 |
| 7 | 1 | 5.27 | 2021-10-07 23:27:52.573000 | 4 | 3 | 4 |
| 8 | 1 | 4.79 | 2021-09-03 18:37:43.059556 | 4 | 3 | 6 |
| 9 | 1 | 5.58 | 2021-09-10 01:29:58.337788 | 4 | 3 | 6 |
| 10 | 1 | 8.61 | 2021-12-28 14:16:05.720697 | 4 | 2 | 6 |

# 5.

```postgresql
create table shipping_status
(
    shippingid                   bigint primary key,
    status                       text,
    state                        text,
    shipping_start_fact_datetime timestamp,
    shipping_end_fact_datetime   timestamp
);

with tmp as (select distinct shippingid,
                             status,
                             state,
                             lag(state_datetime)
                             over (partition by shippingid order by state_datetime) as shipping_start_fact_datetime,
                             state_datetime                                         as shipping_end_fact_datetime
             from shipping
             where state in ('booked', 'recieved')
             order by shippingid, state_datetime)
select *
from tmp
where status = 'finished';
```

