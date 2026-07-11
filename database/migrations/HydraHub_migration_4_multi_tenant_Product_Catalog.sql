-- Migration 4 — Multi-Tenant Product Catalog

------------------------------------------------
---------Validation function 
------------------------------------------------

CREATE OR REPLACE FUNCTION public.validate_variant_sku()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_org_id INTEGER;
BEGIN
    -- Find the organization that owns this product
    SELECT organization_id
      INTO v_org_id
    FROM products
    WHERE product_id = NEW.product_id;

    IF v_org_id IS NULL THEN
        RAISE EXCEPTION
            'Product % does not belong to an organization.',
            NEW.product_id;
    END IF;

    -- Look for another variant using the same SKU
    IF EXISTS (
        SELECT 1
        FROM product_variants pv
        JOIN products p
          ON p.product_id = pv.product_id
        WHERE p.organization_id = v_org_id
          AND pv.sku = NEW.sku
          AND pv.variant_id <> COALESCE(NEW.variant_id, -1)
    ) THEN
        RAISE EXCEPTION
            'SKU "%" already exists for organization %.',
            NEW.sku,
            v_org_id;
    END IF;

    RETURN NEW;
END;
$$;

------------------------------------------------------------
--------------Attach the trigger
------------------------------------------------------------
CREATE TRIGGER trg_validate_variant_sku
BEFORE INSERT OR UPDATE OF sku, product_id
ON product_variants
FOR EACH ROW
EXECUTE FUNCTION public.validate_variant_sku();

------------------------------------------------------------
----------------Refractor Validate_variant_sku()
------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validate_variant_sku()
RETURNS TRIGGER
LANGUAGE plpgsql
AS
$$
DECLARE
    v_org_id INTEGER;
BEGIN
    -------------------------------------------------------------------------
    -- Normalize SKU into HydraHub's canonical business-identifier format
    -------------------------------------------------------------------------
    NEW.sku := util.normalize_business_identifier(NEW.sku);

    -------------------------------------------------------------------------
    -- Reject NULL, empty, or whitespace-only SKUs
    -------------------------------------------------------------------------
    IF NEW.sku IS NULL OR NEW.sku = '' THEN
        RAISE EXCEPTION
            USING
                ERRCODE = '23514',
                MESSAGE = 'SKU cannot be blank.';
    END IF;

    -------------------------------------------------------------------------
    -- Retrieve the organization that owns the selected product
    -------------------------------------------------------------------------
    SELECT p.organization_id
    INTO STRICT v_org_id
    FROM public.products p
    WHERE p.product_id = NEW.product_id;

    -------------------------------------------------------------------------
    -- Enforce organization-scoped SKU uniqueness
    -------------------------------------------------------------------------
    IF EXISTS
    (
        SELECT 1
        FROM public.product_variants pv
        JOIN public.products p
            ON p.product_id = pv.product_id
        WHERE p.organization_id = v_org_id
          AND util.normalize_business_identifier(pv.sku) = NEW.sku
          AND pv.variant_id <> COALESCE(NEW.variant_id, -1)
    )
    THEN
        RAISE EXCEPTION
            USING
                ERRCODE = '23505',
                MESSAGE = format(
                    'SKU "%s" already exists within organization %s.',
                    NEW.sku,
                    v_org_id
                );
    END IF;

    RETURN NEW;

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE EXCEPTION
            USING
                ERRCODE = '23503',
                MESSAGE = format(
                    'Product ID %s does not exist.',
                    NEW.product_id
                );
END;
$$;

----------------------------------------------------------------
-----------Normalization Function 
----------------------------------------------------------------
CREATE OR REPLACE FUNCTION util.normalize_business_identifier(
    p_value TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS
$$
BEGIN
    IF p_value IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN UPPER(TRIM(p_value));
END;
$$;

--------------------------------------------------------------------
-----------parent-validation function
--------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validate_product_organization_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS
$$
DECLARE
    v_conflicting_sku TEXT;
BEGIN
    -------------------------------------------------------------------------
    -- No validation is needed when the organization did not actually change
    -------------------------------------------------------------------------
    IF NEW.organization_id IS NOT DISTINCT FROM OLD.organization_id THEN
        RETURN NEW;
    END IF;

    -------------------------------------------------------------------------
    -- Find any SKU belonging to this product that already exists in the
    -- destination organization
    -------------------------------------------------------------------------
    SELECT util.normalize_business_identifier(pv.sku)
    INTO v_conflicting_sku
    FROM public.product_variants pv
    WHERE pv.product_id = OLD.product_id
      AND EXISTS
      (
          SELECT 1
          FROM public.product_variants existing_pv
          JOIN public.products existing_p
            ON existing_p.product_id = existing_pv.product_id
          WHERE existing_p.organization_id = NEW.organization_id
            AND existing_p.product_id <> OLD.product_id
            AND util.normalize_business_identifier(existing_pv.sku)
                = util.normalize_business_identifier(pv.sku)
      )
    LIMIT 1;

    -------------------------------------------------------------------------
    -- Reject the move when an organization-scoped SKU conflict exists
    -------------------------------------------------------------------------
    IF v_conflicting_sku IS NOT NULL THEN
        RAISE EXCEPTION
            USING
                ERRCODE = '23505',
                MESSAGE = format(
                    'Product ID %s cannot be moved to organization %s because SKU "%s" already exists there.',
                    OLD.product_id,
                    NEW.organization_id,
                    v_conflicting_sku
                );
    END IF;

    RETURN NEW;
END;
$$;
-------------------------------------------------------------------
-----------------Attach trigger to products
-------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_validate_product_organization_change
ON public.products;

CREATE TRIGGER trg_validate_product_organization_change
BEFORE UPDATE OF organization_id
ON public.products
FOR EACH ROW
EXECUTE FUNCTION public.validate_product_organization_change();

---------------------------------------------------------------------
--------------------------Reusable SKU-conflict Funcion
---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventory.organization_sku_exists
(
    p_organization_id    INTEGER,
    p_sku                TEXT,
    p_exclude_variant_id INTEGER DEFAULT NULL,
    p_exclude_product_id INTEGER DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
AS
$$
    SELECT EXISTS
    (
        SELECT 1
        FROM public.product_variants pv
        JOIN public.products p
          ON p.product_id = pv.product_id
        WHERE p.organization_id = p_organization_id
          AND util.normalize_business_identifier(pv.sku)
              = util.normalize_business_identifier(p_sku)
          AND
          (
              p_exclude_variant_id IS NULL
              OR pv.variant_id <> p_exclude_variant_id
          )
          AND
          (
              p_exclude_product_id IS NULL
              OR p.product_id <> p_exclude_product_id
          )
    );
$$;

------------------------------------------------------------
-------------Update Variant_sku
------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validate_variant_sku()
RETURNS TRIGGER
LANGUAGE plpgsql
AS
$$
DECLARE
    v_org_id INTEGER;
BEGIN
    -------------------------------------------------------------------------
    -- Normalize SKU into HydraHub's canonical identifier format
    -------------------------------------------------------------------------
    NEW.sku := util.normalize_business_identifier(NEW.sku);

    -------------------------------------------------------------------------
    -- Reject NULL, empty, or whitespace-only SKUs
    -------------------------------------------------------------------------
    IF NEW.sku IS NULL OR NEW.sku = '' THEN
        RAISE EXCEPTION
            USING
                ERRCODE = '23514',
                MESSAGE = 'SKU cannot be blank.';
    END IF;

    -------------------------------------------------------------------------
    -- Retrieve the organization that owns the selected product
    -------------------------------------------------------------------------
    SELECT p.organization_id
    INTO STRICT v_org_id
    FROM public.products p
    WHERE p.product_id = NEW.product_id;

    -------------------------------------------------------------------------
    -- Enforce organization-scoped SKU uniqueness
    -------------------------------------------------------------------------
    IF inventory.organization_sku_exists
    (
        p_organization_id    => v_org_id,
        p_sku                => NEW.sku,
        p_exclude_variant_id => NEW.variant_id
    )
    THEN
        RAISE EXCEPTION
            USING
                ERRCODE = '23505',
                MESSAGE = format(
                    'SKU "%s" already exists within organization %s.',
                    NEW.sku,
                    v_org_id
                );
    END IF;

    RETURN NEW;

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE EXCEPTION
            USING
                ERRCODE = '23503',
                MESSAGE = format(
                    'Product ID %s does not exist.',
                    NEW.product_id
                );
END;
$$;
-------------------------------------------------------------------
---------------update parent-protection function
-------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validate_product_organization_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS
$$
DECLARE
    v_sku             TEXT;
    v_conflicting_sku TEXT;
BEGIN
    -------------------------------------------------------------------------
    -- Skip when organization_id did not change
    -------------------------------------------------------------------------
    IF NEW.organization_id IS NOT DISTINCT FROM OLD.organization_id THEN
        RETURN NEW;
    END IF;

    -------------------------------------------------------------------------
    -- Acquire destination organization/SKU locks in deterministic order
    -------------------------------------------------------------------------
    FOR v_sku IN
        SELECT DISTINCT
            util.normalize_business_identifier(pv.sku)
        FROM public.product_variants pv
        WHERE pv.product_id = OLD.product_id
        ORDER BY 1
    LOOP
        PERFORM inventory.lock_organization_sku(
            p_organization_id => NEW.organization_id,
            p_sku             => v_sku
        );
    END LOOP;

    -------------------------------------------------------------------------
    -- Check for a collision after all relevant locks are held
    -------------------------------------------------------------------------
    SELECT util.normalize_business_identifier(pv.sku)
    INTO v_conflicting_sku
    FROM public.product_variants pv
    WHERE pv.product_id = OLD.product_id
      AND inventory.organization_sku_exists
      (
          p_organization_id    => NEW.organization_id,
          p_sku                => pv.sku,
          p_exclude_product_id => OLD.product_id
      )
    ORDER BY pv.variant_id
    LIMIT 1;

    IF v_conflicting_sku IS NOT NULL THEN
        RAISE EXCEPTION
            USING
                ERRCODE = '23505',
                MESSAGE = format(
                    'Product ID %s cannot be moved to organization %s because SKU "%s" already exists there.',
                    OLD.product_id,
                    NEW.organization_id,
                    v_conflicting_sku
                );
    END IF;

    RETURN NEW;
END;
$$;
--------------------------------------------------------------------------
------------check for the product trigger
--------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_validate_product_organization_change
ON public.products;

CREATE TRIGGER trg_validate_product_organization_change
BEFORE UPDATE OF organization_id
ON public.products
FOR EACH ROW
EXECUTE FUNCTION public.validate_product_organization_change();

-----------------------------------------------------------------
----------Advisory - lock helper
-----------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventory.lock_organization_sku
(
    p_organization_id INTEGER,
    p_sku             TEXT
)
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
AS
$$
DECLARE
    v_normalized_sku TEXT;
BEGIN
    v_normalized_sku :=
        util.normalize_business_identifier(p_sku);

    IF p_organization_id IS NULL THEN
        RAISE EXCEPTION
            USING
                ERRCODE = '23502',
                MESSAGE = 'Organization ID cannot be NULL when locking an SKU.';
    END IF;

    IF v_normalized_sku IS NULL OR v_normalized_sku = '' THEN
        RAISE EXCEPTION
            USING
                ERRCODE = '23514',
                MESSAGE = 'SKU cannot be blank when acquiring an organization SKU lock.';
    END IF;

    /*
      The lock lasts until the current transaction finishes.

      First key:  organization ID
      Second key: PostgreSQL hash of the normalized SKU
    */
    PERFORM pg_advisory_xact_lock(
        p_organization_id,
        hashtext(v_normalized_sku)
    );
END;
$$;
--------------------------------------------------
-----------updated variant function 
--------------------------------------------------
CREATE OR REPLACE FUNCTION public.validate_variant_sku()
RETURNS TRIGGER
LANGUAGE plpgsql
AS
$$
DECLARE
    v_org_id INTEGER;
BEGIN
    -------------------------------------------------------------------------
    -- Normalize SKU
    -------------------------------------------------------------------------
    NEW.sku := util.normalize_business_identifier(NEW.sku);

    IF NEW.sku IS NULL OR NEW.sku = '' THEN
        RAISE EXCEPTION
            USING
                ERRCODE = '23514',
                MESSAGE = 'SKU cannot be blank.';
    END IF;

    -------------------------------------------------------------------------
    -- Retrieve and lock the parent product row.
    --
    -- FOR SHARE prevents the product from being moved to another
    -- organization while this variant operation is being validated.
    -------------------------------------------------------------------------
    SELECT p.organization_id
    INTO STRICT v_org_id
    FROM public.products p
    WHERE p.product_id = NEW.product_id
    FOR SHARE;

    -------------------------------------------------------------------------
    -- Serialize writes for this organization and normalized SKU
    -------------------------------------------------------------------------
    PERFORM inventory.lock_organization_sku(
        p_organization_id => v_org_id,
        p_sku             => NEW.sku
    );

    -------------------------------------------------------------------------
    -- Check uniqueness after obtaining the lock
    -------------------------------------------------------------------------
    IF inventory.organization_sku_exists
    (
        p_organization_id    => v_org_id,
        p_sku                => NEW.sku,
        p_exclude_variant_id => NEW.variant_id
    )
    THEN
        RAISE EXCEPTION
            USING
                ERRCODE = '23505',
                MESSAGE = format(
                    'SKU "%s" already exists within organization %s.',
                    NEW.sku,
                    v_org_id
                );
    END IF;

    RETURN NEW;

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE EXCEPTION
            USING
                ERRCODE = '23503',
                MESSAGE = format(
                    'Product ID %s does not exist.',
                    NEW.product_id
                );
END;
$$;
--------------------------------------------------------------
