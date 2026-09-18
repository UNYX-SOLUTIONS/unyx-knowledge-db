-- Extensiones específicas de ALTOSA sobre la plantilla común.
-- Los atributos comerciales/específicos se mantienen como columnas porque
-- el workflow de búsqueda de productos los consulta directamente.

ALTER TABLE products ADD COLUMN IF NOT EXISTS producto_actual text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS nombre_catalogo text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS categoria_actual text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS categoria_catalogo text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS subcategoria_catalogo text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS stock_contifico integer;
ALTER TABLE products ADD COLUMN IF NOT EXISTS descripcion_actual text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS materiales_detectados text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS estructura_material text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS tapiceria text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS acabado text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS proteccion_uv text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS resistencia_intemperie text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS apilable text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS giratorio text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS rotacion_360 text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS brazos text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS tipo_brazos text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS soporte_lumbar text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS detalle_soporte_lumbar text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS cabecera text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS detalle_cabecera text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS reclinacion text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS detalle_mecanismo text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS sistema_hidraulico text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS certificacion text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS reposapies text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS ideal_meson_cm text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS uso_recomendado text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS mantenimiento text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS garantia_meses integer;
ALTER TABLE products ADD COLUMN IF NOT EXISTS garantia_especial text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS url_actual text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS fuente_url text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS aprobado text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS keyword text;

CREATE INDEX IF NOT EXISTS idx_altosa_products_aprobado
ON products(aprobado);

CREATE INDEX IF NOT EXISTS idx_altosa_products_categoria_actual
ON products(categoria_actual);

CREATE INDEX IF NOT EXISTS idx_altosa_products_keyword
ON products(keyword);
