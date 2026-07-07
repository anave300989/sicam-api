-- =========================================================
-- SICAM — Sistema de Control de Armamento y Municion
-- Esquema PostgreSQL
-- =========================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto"; -- para gen_random_uuid()

-- ---------------------------------------------------------
-- 1. ROLES Y USUARIOS DEL SISTEMA (quien opera SICAM)
-- ---------------------------------------------------------
CREATE TYPE rol_usuario AS ENUM ('armero', 'oficial_seguridad', 'auditor', 'admin');

CREATE TABLE usuarios (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre          TEXT NOT NULL,
    email           TEXT NOT NULL UNIQUE,
    password_hash   TEXT NOT NULL,
    rol             rol_usuario NOT NULL,
    activo          BOOLEAN NOT NULL DEFAULT TRUE,
    creado_en       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------
-- 2. PERSONAL MILITAR (quien recibe armamento/municion)
-- ---------------------------------------------------------
CREATE TABLE personal (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre      TEXT NOT NULL,
    grado       TEXT NOT NULL,
    unidad      TEXT NOT NULL,
    ci          TEXT UNIQUE,              -- cedula de identidad, opcional pero recomendado
    activo      BOOLEAN NOT NULL DEFAULT TRUE,
    creado_en   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------
-- 3. ARMAMENTO (bien serializado, no fungible)
-- ---------------------------------------------------------
CREATE TYPE estado_arma AS ENUM ('armeria', 'en_uso', 'mantenimiento', 'baja');

CREATE TABLE armas (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    serie           TEXT NOT NULL UNIQUE,
    tipo            TEXT NOT NULL,
    calibre         TEXT NOT NULL,
    estado          estado_arma NOT NULL DEFAULT 'armeria',
    fecha_alta      TIMESTAMPTZ NOT NULL DEFAULT now(),
    observaciones   TEXT
);

CREATE INDEX idx_armas_estado ON armas(estado);

-- ---------------------------------------------------------
-- 4. MUNICION (bien fungible, por lotes)
-- ---------------------------------------------------------
CREATE TABLE lotes_municion (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    lote                TEXT NOT NULL UNIQUE,
    calibre             TEXT NOT NULL,
    cantidad_ingresada  INTEGER NOT NULL CHECK (cantidad_ingresada >= 0),
    cantidad_disponible INTEGER NOT NULL CHECK (cantidad_disponible >= 0),
    fecha_ingreso       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (cantidad_disponible <= cantidad_ingresada)
);

CREATE INDEX idx_lotes_calibre ON lotes_municion(calibre);

-- ---------------------------------------------------------
-- 5. MOVIMIENTOS (salida / retorno) — la transaccion central
-- ---------------------------------------------------------
CREATE TYPE estado_movimiento AS ENUM ('abierto', 'cerrado');

CREATE TABLE movimientos (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    folio           TEXT NOT NULL UNIQUE,          -- ej. SAL-1001
    usuario_id      UUID NOT NULL REFERENCES usuarios(id),   -- armero que registra
    personal_id     UUID NOT NULL REFERENCES personal(id),   -- quien recibe
    proposito       TEXT NOT NULL,
    estado          estado_movimiento NOT NULL DEFAULT 'abierto',
    discrepancia    BOOLEAN NOT NULL DEFAULT FALSE,
    fecha_salida    TIMESTAMPTZ NOT NULL DEFAULT now(),
    fecha_cierre    TIMESTAMPTZ,
    cerrado_por     UUID REFERENCES usuarios(id)
);

CREATE INDEX idx_movimientos_estado ON movimientos(estado);
CREATE INDEX idx_movimientos_personal ON movimientos(personal_id);

-- Detalle: armas incluidas en un movimiento
CREATE TABLE movimiento_armas (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    movimiento_id   UUID NOT NULL REFERENCES movimientos(id) ON DELETE CASCADE,
    arma_id         UUID NOT NULL REFERENCES armas(id),
    devuelta        BOOLEAN,                -- NULL = aun no se cierra el movimiento
    fecha_devolucion TIMESTAMPTZ,
    UNIQUE (movimiento_id, arma_id)
);

-- Detalle: municion entregada/retornada en un movimiento
CREATE TABLE movimiento_municion (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    movimiento_id           UUID NOT NULL REFERENCES movimientos(id) ON DELETE CASCADE,
    lote_id                 UUID NOT NULL REFERENCES lotes_municion(id),
    calibre                 TEXT NOT NULL,
    cantidad_entregada      INTEGER NOT NULL CHECK (cantidad_entregada > 0),
    cantidad_retornada      INTEGER CHECK (cantidad_retornada >= 0),
    cantidad_consumida      INTEGER GENERATED ALWAYS AS
                                (CASE WHEN cantidad_retornada IS NULL THEN NULL
                                      ELSE cantidad_entregada - cantidad_retornada END) STORED,
    CHECK (cantidad_retornada IS NULL OR cantidad_retornada <= cantidad_entregada)
);

-- ---------------------------------------------------------
-- 6. AUDITORIA INMUTABLE (quien hizo que y cuando)
-- ---------------------------------------------------------
CREATE TABLE auditoria (
    id              BIGSERIAL PRIMARY KEY,
    tabla           TEXT NOT NULL,
    registro_id     UUID NOT NULL,
    accion          TEXT NOT NULL,          -- INSERT / UPDATE / DELETE
    usuario_id      UUID,
    datos_anteriores JSONB,
    datos_nuevos     JSONB,
    creado_en       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Nadie puede editar ni borrar registros de auditoria (ni siquiera admin via API)
REVOKE UPDATE, DELETE ON auditoria FROM PUBLIC;

CREATE OR REPLACE FUNCTION fn_auditar() RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO auditoria(tabla, registro_id, accion, datos_nuevos)
        VALUES (TG_TABLE_NAME, NEW.id, 'INSERT', to_jsonb(NEW));
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO auditoria(tabla, registro_id, accion, datos_anteriores, datos_nuevos)
        VALUES (TG_TABLE_NAME, NEW.id, 'UPDATE', to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO auditoria(tabla, registro_id, accion, datos_anteriores)
        VALUES (TG_TABLE_NAME, OLD.id, 'DELETE', to_jsonb(OLD));
        RETURN OLD;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_armas
    AFTER INSERT OR UPDATE OR DELETE ON armas
    FOR EACH ROW EXECUTE FUNCTION fn_auditar();

CREATE TRIGGER trg_audit_lotes
    AFTER INSERT OR UPDATE OR DELETE ON lotes_municion
    FOR EACH ROW EXECUTE FUNCTION fn_auditar();

CREATE TRIGGER trg_audit_movimientos
    AFTER INSERT OR UPDATE OR DELETE ON movimientos
    FOR EACH ROW EXECUTE FUNCTION fn_auditar();

CREATE TRIGGER trg_audit_mov_municion
    AFTER INSERT OR UPDATE OR DELETE ON movimiento_municion
    FOR EACH ROW EXECUTE FUNCTION fn_auditar();

-- ---------------------------------------------------------
-- 7. FUNCIONES DE NEGOCIO (atomicidad garantizada en DB)
-- ---------------------------------------------------------

-- Genera folio correlativo tipo SAL-1001
CREATE SEQUENCE folio_seq START 1000;
CREATE OR REPLACE FUNCTION fn_generar_folio() RETURNS TEXT AS $$
    SELECT 'SAL-' || nextval('folio_seq');
$$ LANGUAGE sql;

-- Registrar salida: valida stock, descuenta municion, marca armas en_uso
-- p_armas: array de UUID de armas
-- p_municion: jsonb array [{"lote_id": "...", "cantidad": 100}, ...]
CREATE OR REPLACE FUNCTION fn_registrar_salida(
    p_usuario_id UUID,
    p_personal_id UUID,
    p_proposito TEXT,
    p_armas UUID[],
    p_municion JSONB
) RETURNS TEXT AS $$
DECLARE
    v_folio TEXT;
    v_movimiento_id UUID;
    v_item JSONB;
    v_disponible INTEGER;
BEGIN
    -- Verificar que las armas esten en armeria (bloqueo de fila para evitar condiciones de carrera)
    IF EXISTS (
        SELECT 1 FROM armas
        WHERE id = ANY(p_armas) AND estado <> 'armeria'
        FOR UPDATE
    ) THEN
        RAISE EXCEPTION 'Una o mas armas no estan disponibles en armeria';
    END IF;

    v_folio := fn_generar_folio();

    INSERT INTO movimientos(folio, usuario_id, personal_id, proposito)
    VALUES (v_folio, p_usuario_id, p_personal_id, p_proposito)
    RETURNING id INTO v_movimiento_id;

    -- Vincular armas y cambiar estado
    IF p_armas IS NOT NULL AND array_length(p_armas, 1) > 0 THEN
        INSERT INTO movimiento_armas(movimiento_id, arma_id)
        SELECT v_movimiento_id, unnest(p_armas);

        UPDATE armas SET estado = 'en_uso' WHERE id = ANY(p_armas);
    END IF;

    -- Vincular municion, validar y descontar stock con bloqueo
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_municion)
    LOOP
        SELECT cantidad_disponible INTO v_disponible
        FROM lotes_municion WHERE id = (v_item->>'lote_id')::UUID
        FOR UPDATE;

        IF v_disponible IS NULL THEN
            RAISE EXCEPTION 'Lote de municion % no existe', v_item->>'lote_id';
        END IF;
        IF v_disponible < (v_item->>'cantidad')::INTEGER THEN
            RAISE EXCEPTION 'Stock insuficiente en lote %', v_item->>'lote_id';
        END IF;

        INSERT INTO movimiento_municion(movimiento_id, lote_id, calibre, cantidad_entregada)
        SELECT v_movimiento_id, (v_item->>'lote_id')::UUID, calibre, (v_item->>'cantidad')::INTEGER
        FROM lotes_municion WHERE id = (v_item->>'lote_id')::UUID;

        UPDATE lotes_municion
        SET cantidad_disponible = cantidad_disponible - (v_item->>'cantidad')::INTEGER
        WHERE id = (v_item->>'lote_id')::UUID;
    END LOOP;

    RETURN v_folio;
END;
$$ LANGUAGE plpgsql;

-- Cerrar movimiento: registra retorno de armas y municion, calcula consumo,
-- detecta discrepancia automaticamente
-- p_armas_devueltas: jsonb [{"arma_id": "...", "devuelta": true}, ...]
-- p_municion_retorno: jsonb [{"lote_id": "...", "retornado": 40}, ...]
CREATE OR REPLACE FUNCTION fn_cerrar_movimiento(
    p_movimiento_id UUID,
    p_cerrado_por UUID,
    p_armas_devueltas JSONB,
    p_municion_retorno JSONB
) RETURNS BOOLEAN AS $$
DECLARE
    v_item JSONB;
    v_discrepancia BOOLEAN := FALSE;
    v_estado estado_movimiento;
BEGIN
    SELECT estado INTO v_estado FROM movimientos WHERE id = p_movimiento_id FOR UPDATE;
    IF v_estado IS NULL THEN
        RAISE EXCEPTION 'Movimiento no encontrado';
    END IF;
    IF v_estado = 'cerrado' THEN
        RAISE EXCEPTION 'El movimiento ya esta cerrado';
    END IF;

    -- Procesar armas devueltas
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_armas_devueltas)
    LOOP
        UPDATE movimiento_armas
        SET devuelta = (v_item->>'devuelta')::BOOLEAN,
            fecha_devolucion = now()
        WHERE movimiento_id = p_movimiento_id
          AND arma_id = (v_item->>'arma_id')::UUID;

        UPDATE armas
        SET estado = (CASE WHEN (v_item->>'devuelta')::BOOLEAN THEN 'armeria' ELSE 'en_uso' END)::estado_arma
        WHERE id = (v_item->>'arma_id')::UUID;

        IF NOT (v_item->>'devuelta')::BOOLEAN THEN
            v_discrepancia := TRUE;   -- arma no devuelta = discrepancia grave
        END IF;
    END LOOP;

    -- Procesar retorno de municion y devolver remanente al stock
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_municion_retorno)
    LOOP
        UPDATE movimiento_municion
        SET cantidad_retornada = (v_item->>'retornado')::INTEGER
        WHERE movimiento_id = p_movimiento_id
          AND lote_id = (v_item->>'lote_id')::UUID;

        UPDATE lotes_municion
        SET cantidad_disponible = cantidad_disponible + (v_item->>'retornado')::INTEGER
        WHERE id = (v_item->>'lote_id')::UUID;
    END LOOP;

    -- Si quedo municion entregada sin dato de retorno, es discrepancia (dato faltante)
    IF EXISTS (
        SELECT 1 FROM movimiento_municion
        WHERE movimiento_id = p_movimiento_id AND cantidad_retornada IS NULL
    ) THEN
        v_discrepancia := TRUE;
    END IF;

    UPDATE movimientos
    SET estado = 'cerrado',
        fecha_cierre = now(),
        cerrado_por = p_cerrado_por,
        discrepancia = v_discrepancia
    WHERE id = p_movimiento_id;

    RETURN v_discrepancia;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------
-- 8. VISTAS DE REPORTE
-- ---------------------------------------------------------

-- Vista: movimientos con discrepancia, para el resumen ejecutivo de seguridad
CREATE VIEW vw_discrepancias AS
SELECT
    m.folio,
    m.fecha_salida,
    m.fecha_cierre,
    p.nombre AS responsable,
    p.unidad,
    u.nombre AS registrado_por,
    m.proposito
FROM movimientos m
JOIN personal p ON p.id = m.personal_id
JOIN usuarios u ON u.id = m.usuario_id
WHERE m.discrepancia = TRUE;

-- Vista: stock actual consolidado por calibre
CREATE VIEW vw_stock_municion AS
SELECT calibre, SUM(cantidad_disponible) AS disponible_total, COUNT(*) AS lotes
FROM lotes_municion
GROUP BY calibre;

-- Vista: armas actualmente fuera de armeria (para control diario)
CREATE VIEW vw_armas_en_uso AS
SELECT a.serie, a.tipo, a.calibre, m.folio, p.nombre AS responsable, p.unidad, m.fecha_salida
FROM armas a
JOIN movimiento_armas ma ON ma.arma_id = a.id AND ma.devuelta IS NOT TRUE
JOIN movimientos m ON m.id = ma.movimiento_id AND m.estado = 'abierto'
JOIN personal p ON p.id = m.personal_id;
