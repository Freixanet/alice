"""Purchase kill switch. Re-enabling requires an explicit reviewed source change."""
ENABLED = False
MESSAGE = "Las compras y los pagos están desactivados temporalmente. Vigilancias y tareas de revisión siguen disponibles."
TOOLS = frozenset({"errand_start", "checkout_request", "card_request", "purchase_discover", "purchase_verify", "purchase_check_cart", "login_request", "login_fill", "purchase_options", "purchase_browser", "purchase_outcome", "product_list", "catalog_search", "catalog_product"})
