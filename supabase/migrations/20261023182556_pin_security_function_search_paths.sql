-- Pin the lookup path of helper functions used by sensitive-data validation.
-- This prevents objects in a caller-controlled schema from shadowing built-ins.
alter function memohub.entity_types() set search_path = memohub, pg_catalog;
alter function memohub._luhn_ok(text) set search_path = memohub, pg_catalog;
alter function memohub._iban_ok(text) set search_path = memohub, pg_catalog;
