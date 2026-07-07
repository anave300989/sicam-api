/**
 * SICAM API — Sistema de Control de Armamento y Municion
 * Node.js + Express + PostgreSQL (pg)
 *
 * Instalacion:
 *   npm install express pg jsonwebtoken bcrypt dotenv cors
 *
 * Variables de entorno (.env):
 *   DATABASE_URL=postgres://usuario:password@localhost:5432/sicam
 *   JWT_SECRET=cambiar-esto-por-un-secreto-largo-y-aleatorio
 *   PORT=4000
 */

require('dotenv').config();
const express = require('express');
const cors = require('cors');
const jwt = require('jsonwebtoken');
const bcrypt = require('bcrypt');
const { Pool } = require('pg');

const app = express();
app.use(cors());
app.use(express.json());

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.DATABASE_URL?.includes('render.com') ? { rejectUnauthorized: false } : false,
});

// =========================================================
// AUTENTICACION
// =========================================================

function firmarToken(usuario) {
  return jwt.sign(
    { id: usuario.id, rol: usuario.rol, nombre: usuario.nombre },
    process.env.JWT_SECRET,
    { expiresIn: '8h' }
  );
}

function requiereAuth(req, res, next) {
  const header = req.headers.authorization;
  if (!header) return res.status(401).json({ error: 'Token no proporcionado' });
  try {
    req.usuario = jwt.verify(header.replace('Bearer ', ''), process.env.JWT_SECRET);
    next();
  } catch {
    return res.status(401).json({ error: 'Token invalido o expirado' });
  }
}

// Restringe una ruta a ciertos roles. Ej: requiereRol('armero', 'admin')
function requiereRol(...rolesPermitidos) {
  return (req, res, next) => {
    if (!rolesPermitidos.includes(req.usuario.rol)) {
      return res.status(403).json({ error: 'No tiene permisos para esta accion' });
    }
    next();
  };
}

app.post('/auth/login', async (req, res) => {
  const { email, password } = req.body;
  const { rows } = await pool.query('SELECT * FROM usuarios WHERE email = $1 AND activo = TRUE', [email]);
  const usuario = rows[0];
  if (!usuario || !(await bcrypt.compare(password, usuario.password_hash))) {
    return res.status(401).json({ error: 'Credenciales invalidas' });
  }
  res.json({ token: firmarToken(usuario), usuario: { id: usuario.id, nombre: usuario.nombre, rol: usuario.rol } });
});

// =========================================================
// INVENTARIO — ARMAS
// =========================================================

app.get('/armas', requiereAuth, async (req, res) => {
  const { estado } = req.query;
  const { rows } = await pool.query(
    estado ? 'SELECT * FROM armas WHERE estado = $1 ORDER BY serie' : 'SELECT * FROM armas ORDER BY serie',
    estado ? [estado] : []
  );
  res.json(rows);
});

app.post('/armas', requiereAuth, requiereRol('armero', 'admin'), async (req, res) => {
  const { serie, tipo, calibre, observaciones } = req.body;
  try {
    const { rows } = await pool.query(
      `INSERT INTO armas (serie, tipo, calibre, observaciones) VALUES ($1,$2,$3,$4) RETURNING *`,
      [serie, tipo, calibre, observaciones || null]
    );
    res.status(201).json(rows[0]);
  } catch (err) {
    if (err.code === '23505') return res.status(409).json({ error: 'Ya existe un arma con esa serie' });
    res.status(500).json({ error: 'Error al registrar el arma' });
  }
});

// Dar de baja / enviar a mantenimiento (cambio de estado administrativo, no via movimiento)
app.patch('/armas/:id/estado', requiereAuth, requiereRol('armero', 'admin'), async (req, res) => {
  const { estado } = req.body; // 'mantenimiento' | 'baja' | 'armeria'
  const { rows } = await pool.query(
    `UPDATE armas SET estado = $1 WHERE id = $2 AND estado <> 'en_uso' RETURNING *`,
    [estado, req.params.id]
  );
  if (!rows[0]) return res.status(409).json({ error: 'El arma esta en uso; ciérrela primero por movimiento' });
  res.json(rows[0]);
});

// =========================================================
// INVENTARIO — MUNICION
// =========================================================

app.get('/municion/lotes', requiereAuth, async (req, res) => {
  const { rows } = await pool.query('SELECT * FROM lotes_municion ORDER BY calibre, lote');
  res.json(rows);
});

app.get('/municion/stock', requiereAuth, async (req, res) => {
  const { rows } = await pool.query('SELECT * FROM vw_stock_municion ORDER BY calibre');
  res.json(rows);
});

app.post('/municion/lotes', requiereAuth, requiereRol('armero', 'admin'), async (req, res) => {
  const { lote, calibre, cantidad_ingresada } = req.body;
  try {
    const { rows } = await pool.query(
      `INSERT INTO lotes_municion (lote, calibre, cantidad_ingresada, cantidad_disponible)
       VALUES ($1,$2,$3,$3) RETURNING *`,
      [lote, calibre, cantidad_ingresada]
    );
    res.status(201).json(rows[0]);
  } catch (err) {
    if (err.code === '23505') return res.status(409).json({ error: 'Ya existe un lote con ese numero' });
    res.status(500).json({ error: 'Error al registrar el lote' });
  }
});

// =========================================================
// PERSONAL
// =========================================================

app.get('/personal', requiereAuth, async (req, res) => {
  const { rows } = await pool.query('SELECT * FROM personal WHERE activo = TRUE ORDER BY nombre');
  res.json(rows);
});

app.post('/personal', requiereAuth, requiereRol('armero', 'admin'), async (req, res) => {
  const { nombre, grado, unidad, ci } = req.body;
  const { rows } = await pool.query(
    `INSERT INTO personal (nombre, grado, unidad, ci) VALUES ($1,$2,$3,$4) RETURNING *`,
    [nombre, grado, unidad, ci || null]
  );
  res.status(201).json(rows[0]);
});

// =========================================================
// MOVIMIENTOS — SALIDA
// =========================================================

/**
 * body: {
 *   personal_id, proposito,
 *   armas: [uuid, ...],
 *   municion: [{ lote_id, cantidad }, ...]
 * }
 */
app.post('/movimientos/salida', requiereAuth, requiereRol('armero', 'admin'), async (req, res) => {
  const { personal_id, proposito, armas = [], municion = [] } = req.body;
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { rows } = await client.query(
      `SELECT fn_registrar_salida($1,$2,$3,$4,$5) AS folio`,
      [req.usuario.id, personal_id, proposito, armas, JSON.stringify(municion)]
    );
    await client.query('COMMIT');
    res.status(201).json({ folio: rows[0].folio });
  } catch (err) {
    await client.query('ROLLBACK');
    res.status(400).json({ error: err.message });
  } finally {
    client.release();
  }
});

// Movimientos abiertos (pendientes de retorno)
app.get('/movimientos/abiertos', requiereAuth, async (req, res) => {
  const { rows } = await pool.query(`
    SELECT m.*, p.nombre AS responsable, p.unidad
    FROM movimientos m JOIN personal p ON p.id = m.personal_id
    WHERE m.estado = 'abierto' ORDER BY m.fecha_salida DESC
  `);
  res.json(rows);
});

// Detalle completo de un movimiento (armas + municion)
app.get('/movimientos/:id', requiereAuth, async (req, res) => {
  const { id } = req.params;
  const [mov, arm, mun] = await Promise.all([
    pool.query(`SELECT m.*, p.nombre AS responsable, p.unidad FROM movimientos m
                JOIN personal p ON p.id = m.personal_id WHERE m.id = $1`, [id]),
    pool.query(`SELECT ma.*, a.serie, a.tipo, a.calibre FROM movimiento_armas ma
                JOIN armas a ON a.id = ma.arma_id WHERE ma.movimiento_id = $1`, [id]),
    pool.query(`SELECT * FROM movimiento_municion WHERE movimiento_id = $1`, [id]),
  ]);
  if (!mov.rows[0]) return res.status(404).json({ error: 'Movimiento no encontrado' });
  res.json({ ...mov.rows[0], armas: arm.rows, municion: mun.rows });
});

// =========================================================
// MOVIMIENTOS — CIERRE / RETORNO
// =========================================================

/**
 * body: {
 *   armas_devueltas: [{ arma_id, devuelta: true|false }, ...],
 *   municion_retorno: [{ lote_id, retornado: number }, ...]
 * }
 */
app.post('/movimientos/:id/cerrar', requiereAuth, requiereRol('armero', 'admin'), async (req, res) => {
  const { armas_devueltas = [], municion_retorno = [] } = req.body;
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { rows } = await client.query(
      `SELECT fn_cerrar_movimiento($1,$2,$3,$4) AS discrepancia`,
      [req.params.id, req.usuario.id, JSON.stringify(armas_devueltas), JSON.stringify(municion_retorno)]
    );
    await client.query('COMMIT');
    res.json({ cerrado: true, discrepancia: rows[0].discrepancia });
  } catch (err) {
    await client.query('ROLLBACK');
    res.status(400).json({ error: err.message });
  } finally {
    client.release();
  }
});

// =========================================================
// REPORTES / AUDITORIA (rol auditor y oficial de seguridad)
// =========================================================

app.get('/reportes/discrepancias', requiereAuth, requiereRol('oficial_seguridad', 'auditor', 'admin'), async (req, res) => {
  const { rows } = await pool.query('SELECT * FROM vw_discrepancias ORDER BY fecha_salida DESC');
  res.json(rows);
});

app.get('/reportes/armas-en-uso', requiereAuth, requiereRol('oficial_seguridad', 'auditor', 'admin'), async (req, res) => {
  const { rows } = await pool.query('SELECT * FROM vw_armas_en_uso ORDER BY fecha_salida');
  res.json(rows);
});

// Resumen ejecutivo semanal: para el parte de seguridad
app.get('/reportes/resumen-semanal', requiereAuth, requiereRol('oficial_seguridad', 'auditor', 'admin'), async (req, res) => {
  const { rows: totales } = await pool.query(`
    SELECT
      (SELECT COUNT(*) FROM movimientos WHERE fecha_salida > now() - interval '7 days') AS movimientos_semana,
      (SELECT COUNT(*) FROM movimientos WHERE discrepancia = TRUE AND fecha_salida > now() - interval '7 days') AS discrepancias_semana,
      (SELECT COUNT(*) FROM armas WHERE estado = 'en_uso') AS armas_en_uso_actual
  `);
  const { rows: stock } = await pool.query('SELECT * FROM vw_stock_municion');
  res.json({ ...totales[0], stock_municion: stock });
});

// Auditoria cruda de un registro especifico (trazabilidad total)
app.get('/auditoria/:tabla/:registroId', requiereAuth, requiereRol('auditor', 'admin'), async (req, res) => {
  const { rows } = await pool.query(
    `SELECT * FROM auditoria WHERE tabla = $1 AND registro_id = $2 ORDER BY creado_en`,
    [req.params.tabla, req.params.registroId]
  );
  res.json(rows);
});

// =========================================================
app.listen(process.env.PORT || 4000, () => {
  console.log(`SICAM API escuchando en puerto ${process.env.PORT || 4000}`);
});
