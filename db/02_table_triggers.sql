-- SQLChain: Triggers for Tables


CREATE OR REPLACE FUNCTION ledger_insert_trigger_fn()
RETURNS trigger AS $$
BEGIN
    -- RAISE NOTICE 'A new ledger row was inserted: id=%, credits=% pub=%', NEW.id, NEW.credits, NEW.pub,;

    -- Create a role for this ledger entry
    EXECUTE format('CREATE ROLE role_%s', NEW.id);
    -- Create a schema owned by that role
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS schema_%s AUTHORIZATION role_%s',
                   NEW.id, NEW.id);
    EXECUTE format('GRANT USAGE ON SCHEMA public TO role_%s', NEW.id);

    -- Return NEW to allow the insert to continue
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER ledger_insert_trigger
AFTER INSERT ON ledger
FOR EACH ROW
EXECUTE FUNCTION ledger_insert_trigger_fn();

