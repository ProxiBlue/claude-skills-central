#!/bin/bash
# prod-shape-collect.sh — capture a Magento DB's *shape* (counts/distributions,
# never rows) as JSON for plan-time agent context. AP-3, 2026-08-03.
#
# PRIVACY: every query is an aggregate (COUNT/GROUP BY/MAX). No customer data,
# no order data, no PII leaves the database — only numbers.
#
# RUN BY THE OPERATOR on the production host (agents never touch prod):
#     bash prod-shape-collect.sh <db-name> > prod-shape.json
# then drop the file at <project>/.claude/prod-shape.json on the workstation.
# The script is self-contained — copy-paste or scp it to the prod shell.
#
# Local/dev test (ddev):  SHAPE_MYSQL="mysql -hdb -uroot -proot" bash prod-shape-collect.sh db
#
# Read-only: SELECTs only. Cheap: exact counts on curated tables (~1s each on
# a few-hundred-k-row table), information_schema size estimates for the rest.

set -u
DB="${1:-}"
[ -z "$DB" ] && { echo "usage: prod-shape-collect.sh <db-name>" >&2; exit 2; }
MYSQL="${SHAPE_MYSQL:-mysql}"

q() {  # run one scalar query, print value (empty on error — table may not exist)
  # shellcheck disable=SC2086
  $MYSQL -N -e "$1" "$DB" 2>/dev/null | head -1
}

num() {  # numeric or null for JSON
  local v; v=$(q "$1")
  case "$v" in ''|NULL) echo null ;; *) echo "$v" ;; esac
}

# --- curated exact counts (the tables that change design decisions) ----------
TABLES="catalog_product_entity catalog_category_entity catalog_product_entity_varchar
catalog_product_entity_int catalog_product_super_link catalog_category_product
sales_order sales_order_item customer_entity customer_address_entity
url_rewrite quote quote_item cms_page cms_block eav_attribute
catalog_product_option inventory_source_item review wishlist"

first=1
tables_json="{"
for t in $TABLES; do
  c=$(num "SELECT COUNT(*) FROM \`$t\`")
  [ "$c" = "null" ] && continue
  [ "$first" = "0" ] && tables_json+=","
  tables_json+="\"$t\":$c"
  first=0
done
tables_json+="}"

# --- top-15 largest tables by size (estimates — catches surprises) -----------
largest=$($MYSQL -N -e "
  SELECT CONCAT('\"', TABLE_NAME, '\":{\"est_rows\":', IFNULL(TABLE_ROWS,0),
                ',\"mb\":', ROUND((DATA_LENGTH+INDEX_LENGTH)/1048576), '}')
  FROM information_schema.TABLES
  WHERE TABLE_SCHEMA='$DB'
  ORDER BY DATA_LENGTH+INDEX_LENGTH DESC LIMIT 15" 2>/dev/null | paste -sd, -)

# --- distributions (aggregates only) -----------------------------------------
orders_pm=$(num "SELECT ROUND(COUNT(*)/12) FROM sales_order
                 WHERE created_at >= DATE_SUB(NOW(), INTERVAL 12 MONTH)")
items_per_order=$(num "SELECT ROUND(AVG(cnt),1) FROM
  (SELECT COUNT(*) cnt FROM sales_order_item GROUP BY order_id) t")
# p95 without window functions (MySQL/MariaDB-version-safe): two steps
cat_count=$(num "SELECT COUNT(DISTINCT category_id) FROM catalog_category_product")
if [ "$cat_count" != "null" ] && [ "$cat_count" -gt 0 ] 2>/dev/null; then
  offset=$(( cat_count * 95 / 100 ))
  prod_per_cat_p95=$(num "SELECT cnt FROM (
      SELECT COUNT(*) cnt FROM catalog_category_product GROUP BY category_id
      ORDER BY cnt) t LIMIT 1 OFFSET $offset")
else
  prod_per_cat_p95=null
fi
max_opts=$(num "SELECT IFNULL(MAX(cnt),0) FROM (
    SELECT COUNT(*) cnt FROM catalog_product_option GROUP BY product_id) t")
configurable_children_max=$(num "SELECT IFNULL(MAX(cnt),0) FROM (
    SELECT COUNT(*) cnt FROM catalog_product_super_link GROUP BY parent_id) t")
websites=$(num "SELECT COUNT(*) FROM store_website")
stores=$(num "SELECT COUNT(*) FROM store")

cat <<EOF
{
  "captured": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "db": "$DB",
  "host": "$(hostname 2>/dev/null || echo unknown)",
  "tables": $tables_json,
  "largest_tables": {$largest},
  "distributions": {
    "orders_per_month_avg_12m": $orders_pm,
    "items_per_order_avg": $items_per_order,
    "products_per_category_p95": $prod_per_cat_p95,
    "max_custom_options_per_product": $max_opts,
    "max_children_per_configurable": $configurable_children_max,
    "websites": $websites,
    "stores": $stores
  }
}
EOF
