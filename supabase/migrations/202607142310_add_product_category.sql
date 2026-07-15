alter table public.productos
  add column if not exists categoria text;

update public.productos
set categoria = 'burgers'
where categoria is null or btrim(categoria) = '';

alter table public.productos
  alter column categoria set default 'burgers';

alter table public.productos
  alter column categoria set not null;
