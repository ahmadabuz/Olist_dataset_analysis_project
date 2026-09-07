-- --------------------------------------------------------------
-- Q1. Monthly revenue trend with month-over-month growth
-- --------------------------------------------------------------
CREATE OR REPLACE VIEW v_monthly_revenue AS
WITH monthly AS (
    SELECT
        DATE_TRUNC('month', o.order_purchase_timestamp)::date AS order_month,
        SUM(oi.price + oi.freight_value) AS revenue,
        COUNT(DISTINCT o.order_id) AS orders
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.order_status NOT IN ('canceled', 'unavailable')
    GROUP BY 1
)
SELECT
    order_month,
    revenue,
    orders,
    ROUND(revenue / NULLIF(orders, 0), 2) AS avg_order_value,
    LAG(revenue) OVER (ORDER BY order_month) AS prev_month_revenue,
    ROUND(
        100.0 * (revenue - LAG(revenue) OVER (ORDER BY order_month))
        / NULLIF(LAG(revenue) OVER (ORDER BY order_month), 0), 1
    ) AS mom_growth_pct
FROM monthly
ORDER BY order_month;


-- --------------------------------------------------------------
-- Q2. Customer cohort retention (by first purchase month)
-- --------------------------------------------------------------
CREATE OR REPLACE VIEW v_cohort_retention AS
WITH first_purchase AS (
    SELECT
        c.customer_unique_id,
        MIN(DATE_TRUNC('month', o.order_purchase_timestamp)) AS cohort_month
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    GROUP BY c.customer_unique_id
),
orders_with_cohort AS (
    SELECT
        c.customer_unique_id,
        fp.cohort_month,
        DATE_TRUNC('month', o.order_purchase_timestamp) AS order_month
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    JOIN first_purchase fp ON fp.customer_unique_id = c.customer_unique_id
)
SELECT
    cohort_month,
    order_month,
    (DATE_PART('year', order_month) - DATE_PART('year', cohort_month)) * 12
        + (DATE_PART('month', order_month) - DATE_PART('month', cohort_month)) AS months_since_first_purchase,
    COUNT(DISTINCT customer_unique_id) AS active_customers
FROM orders_with_cohort
GROUP BY cohort_month, order_month
ORDER BY cohort_month, order_month;


-- --------------------------------------------------------------
-- Q3. RFM customer segmentation (Recency, Frequency, Monetary)
-- --------------------------------------------------------------
CREATE OR REPLACE VIEW v_customer_rfm AS
WITH customer_orders AS (
    SELECT
        c.customer_unique_id,
        MAX(o.order_purchase_timestamp) AS last_order_date,
        COUNT(DISTINCT o.order_id) AS frequency,
        SUM(oi.price + oi.freight_value) AS monetary
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.order_status NOT IN ('canceled', 'unavailable')
    GROUP BY c.customer_unique_id
),
scored AS (
    SELECT
        *,
        (SELECT MAX(order_purchase_timestamp) FROM orders) - last_order_date AS recency_interval,
        NTILE(5) OVER (ORDER BY (SELECT MAX(order_purchase_timestamp) FROM orders) - last_order_date DESC) AS recency_score,
        NTILE(5) OVER (ORDER BY frequency) AS frequency_score,
        NTILE(5) OVER (ORDER BY monetary) AS monetary_score
    FROM customer_orders
)
SELECT
    customer_unique_id,
    last_order_date,
    frequency,
    monetary,
    recency_score,
    frequency_score,
    monetary_score,
    (recency_score + frequency_score + monetary_score) AS rfm_total,
    CASE
        WHEN recency_score >= 4 AND frequency_score >= 4 THEN 'Champions'
        WHEN recency_score >= 4 AND frequency_score < 4  THEN 'New / Promising'
        WHEN recency_score < 3  AND frequency_score >= 4 THEN 'At Risk (was loyal)'
        WHEN recency_score < 3  AND frequency_score < 3  THEN 'Lost'
        ELSE 'Needs Attention'
    END AS segment
FROM scored;


-- --------------------------------------------------------------
-- Q4. Delivery delay vs. review score
-- --------------------------------------------------------------
CREATE OR REPLACE VIEW v_delivery_delay_vs_review AS
SELECT
    o.order_id,
    r.review_score,
    o.order_estimated_delivery_date,
    o.order_delivered_customer_date,
    EXTRACT(DAY FROM (o.order_delivered_customer_date - o.order_estimated_delivery_date)) AS days_late,
    CASE
        WHEN o.order_delivered_customer_date IS NULL THEN 'not_delivered'
        WHEN o.order_delivered_customer_date <= o.order_estimated_delivery_date THEN 'on_time_or_early'
        ELSE 'late'
    END AS delivery_bucket
FROM orders o
JOIN order_reviews r ON r.order_id = o.order_id
WHERE o.order_status = 'delivered';

-- Summary rollup for the dashboard:
CREATE OR REPLACE VIEW v_delivery_bucket_avg_review AS
SELECT
    delivery_bucket,
    COUNT(*) AS n_orders,
    ROUND(AVG(review_score), 2) AS avg_review_score
FROM v_delivery_delay_vs_review
GROUP BY delivery_bucket
ORDER BY avg_review_score DESC;


-- --------------------------------------------------------------
-- Q5. Top product categories and sellers by revenue
-- --------------------------------------------------------------
CREATE OR REPLACE VIEW v_top_categories AS
SELECT
    COALESCE(t.product_category_name_english, p.product_category_name, 'unknown') AS category,
    COUNT(DISTINCT oi.order_id) AS orders,
    SUM(oi.price) AS revenue,
    RANK() OVER (ORDER BY SUM(oi.price) DESC) AS revenue_rank
FROM order_items oi
JOIN products p ON p.product_id = oi.product_id
LEFT JOIN product_category_translation t ON t.product_category_name = p.product_category_name
GROUP BY 1
ORDER BY revenue DESC;

CREATE OR REPLACE VIEW v_top_sellers AS
SELECT
    s.seller_id,
    s.seller_state,
    COUNT(DISTINCT oi.order_id) AS orders,
    SUM(oi.price) AS revenue,
    RANK() OVER (ORDER BY SUM(oi.price) DESC) AS revenue_rank
FROM order_items oi
JOIN sellers s ON s.seller_id = oi.seller_id
GROUP BY s.seller_id, s.seller_state
ORDER BY revenue DESC;