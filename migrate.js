/**
 * SICAM — Migracion automatica
 * Se ejecuta automaticamente en el despliegue (Render corre "npm run migrate"
 * antes de arrancar el servidor). Es idempotente: si ya se aplico antes,
 * no hace nada.
 */

require('dotenv').config();
const fs = require('fs');
const path = require('path');
const { Pool } = require('pg');
const bcrypt = require('bcrypt');

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.DATABASE_URL?.includes('render.com') ? { rejectUnauthorized: false } : false,
});

async function tablaExiste(nombre) {
  const { rows } = await pool.query('SELECT to_regclass($1) AS existe', [`public.${nombre}`]);
  return rows[0].existe !== null;
}

async function aplicarEsquema() {
  const existe = await tablaExiste('usuarios');
  if (existe) {
    console.log('El esquema ya existe, se omite la creacion de tablas.');
    return;
  }
  console.log('Aplicando schema.sql...');
  const schema = fs.readFileSync(path.join(__dirname, 'schema.sql'), 'utf8');
  await pool.query(schema);
  console.log('Esquema aplicado correctamente.');
}

async function crearUsuario(nombre, email, password, rol) {
  const hash = await bcrypt.hash(password, 10);
  await pool.query(
    `INSERT INTO usuarios (nombre, email, password_hash, rol)
     VALUES ($1,$2,$3,$4)
     ON CONFLICT (email) DO NOTHING`,
    [nombre, email, hash, rol]
  );
}

async function seed() {
  const yaHayUsuarios = await pool.query('SELECT COUNT(*) FROM usuarios');
  if (Number(yaHayUsuarios.rows[0].count) > 0) {
    console.log('Ya existen usuarios, se omite el seed.');
    return;
  }

  console.log('Creando datos iniciales...');
  await crearUsuario('Administrador SICAM', 'admin@sicam.mil.bo', 'ChangeMe!2026', 'admin');
  await crearUsuario('Sgto. Rojas', 'armero@sicam.mil.bo', 'ChangeMe!2026', 'armero');
  await crearUsuario('My. Fernandez', 'oficial@sicam.mil.bo', 'ChangeMe!2026', 'oficial_seguridad');

  await pool.query(`
    INSERT INTO personal (nombre, grado, unidad, ci) VALUES
      ('Juan Perez Mamani', 'Cabo 1ro.', 'RI-1 Colorados', '5551234'),
      ('Maria Quispe Choque', 'Sgto. 2do.', 'RPM-1 Cap. Saavedra', '6672345')
    ON CONFLICT (ci) DO NOTHING;
  `);

  await pool.query(`
    INSERT INTO armas (serie, tipo, calibre) VALUES
      ('FAL-00214', 'Fusil FAL', '7.62x51'),
      ('FAL-00215', 'Fusil FAL', '7.62x51'),
      ('GAL-00981', 'Fusil Galil', '5.56x45'),
      ('PT-01187',  'Pistola PT-92', '9x19')
    ON CONFLICT (serie) DO NOTHING;
  `);

  await pool.query(`
    INSERT INTO lotes_municion (lote, calibre, cantidad_ingresada, cantidad_disponible) VALUES
      ('LP-2026-014', '7.62x51', 4000, 4000),
      ('LP-2026-021', '5.56x45', 6000, 6000),
      ('LP-2026-009', '9x19',    2500, 2500)
    ON CONFLICT (lote) DO NOTHING;
  `);

  console.log('Seed completo.');
  console.log('  admin@sicam.mil.bo   / ChangeMe!2026');
  console.log('  armero@sicam.mil.bo  / ChangeMe!2026');
  console.log('  oficial@sicam.mil.bo / ChangeMe!2026');
}

async function main() {
  await aplicarEsquema();
  await seed();
  await pool.end();
}

main().catch((err) => {
  console.error('Error en migracion:', err);
  process.exit(1);
});
