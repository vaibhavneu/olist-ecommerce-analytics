-- Query 1: Monthly Revenue Trend
WITH monthly_revenue AS (
    SELECT
        d.year,
        d.month,
        d.month_name,
        ROUND(SUM(f.payment_value), 2) AS total_revenue,
        COUNT(DISTINCT f.order_id) AS total_orders,
        ROUND(SUM(f.payment_value) / COUNT(DISTINCT f.order_id), 2) AS avg_order_value
    FROM fact_orders f
    JOIN dim_date d ON f.order_purchase_date = d.date_id
    WHERE f.order_status = 'delivered'
    GROUP BY d.year, d.month, d.month_name
)
SELECT
    year,
    month,
    month_name,
    total_revenue,
    total_orders,
    avg_order_value,
    LAG(total_revenue) OVER (ORDER BY year, month) AS prev_month_revenue,
    ROUND(
        (total_revenue - LAG(total_revenue) OVER (ORDER BY year, month)) 
        / LAG(total_revenue) OVER (ORDER BY year, month) * 100, 1
    ) AS mom_growth_pct
FROM monthly_revenue
ORDER BY year, month;
-- Query 2: Top Revenue Categories
SELECT
    p.product_category_english AS category,
    COUNT(DISTINCT f.order_id) AS total_orders,
    ROUND(SUM(f.payment_value), 2) AS total_revenue,
    ROUND(AVG(f.payment_value), 2) AS avg_order_value,
    ROUND(AVG(f.review_score), 2) AS avg_review_score
FROM fact_orders f
JOIN dim_products p ON f.product_id = p.product_id
WHERE f.order_status = 'delivered'
    AND p.product_category_english IS NOT NULL
GROUP BY p.product_category_english
ORDER BY total_revenue DESC
LIMIT 15;

-- Query 3: Customer Repeat Purchase Rate
WITH customer_orders AS (
    SELECT
        customer_unique_id,
        COUNT(DISTINCT order_id) AS total_orders
    FROM fact_orders
    WHERE order_status = 'delivered'
    GROUP BY customer_unique_id
),
customer_segments AS (
    SELECT
        total_orders,
        CASE
            WHEN total_orders = 1 THEN 'One-time buyer'
            WHEN total_orders = 2 THEN 'Repeat buyer (2x)'
            WHEN total_orders >= 3 THEN 'Loyal buyer (3x+)'
        END AS buyer_type,
        COUNT(*) AS customer_count
    FROM customer_orders
    GROUP BY total_orders,buyer_type
)
SELECT
    buyer_type,
    SUM(customer_count) AS customer_count,
    ROUND(SUM(customer_count) * 100.0 / (SELECT COUNT(*) FROM customer_orders), 1) AS pct_of_customers
FROM customer_segments
GROUP BY buyer_type
ORDER BY customer_count DESC;

-- Query 4: Delivery Performance & SLA Analysis
SELECT
    CASE
        WHEN order_delivered_date <= order_estimated_delivery THEN 'On Time'
        ELSE 'Late'
    END AS delivery_status,
    COUNT(*) AS total_orders,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct_of_orders,
    ROUND(AVG(DATEDIFF(order_delivered_date, order_purchase_date)), 1) AS avg_delivery_days,
    ROUND(AVG(review_score), 2) AS avg_review_score,
    ROUND(AVG(DATEDIFF(order_estimated_delivery, order_delivered_date)), 1) AS avg_days_early_or_late
FROM fact_orders
WHERE order_status = 'delivered'
    AND order_delivered_date IS NOT NULL
    AND order_estimated_delivery IS NOT NULL
GROUP BY delivery_status
ORDER BY total_orders DESC;

-- Query 5: Top Performing Sellers
SELECT
    f.seller_id,
    s.seller_city,
    s.seller_state,
    COUNT(DISTINCT f.order_id) AS total_orders,
    ROUND(SUM(f.payment_value), 2) AS total_revenue,
    ROUND(AVG(f.review_score), 2) AS avg_review_score,
    ROUND(AVG(DATEDIFF(f.order_delivered_date, f.order_purchase_date)), 1) AS avg_delivery_days,
    COUNT(DISTINCT f.product_id) AS unique_products
FROM fact_orders f
JOIN dim_sellers s ON f.seller_id = s.seller_id
WHERE f.order_status = 'delivered'
    AND f.order_delivered_date IS NOT NULL
GROUP BY f.seller_id, s.seller_city, s.seller_state
HAVING total_orders >= 50
ORDER BY total_revenue DESC
LIMIT 20;

-- Query 6: Revenue by Customer State
SELECT
    c.customer_state,
    COUNT(DISTINCT f.order_id) AS total_orders,
    ROUND(SUM(f.payment_value), 2) AS total_revenue,
    ROUND(AVG(f.payment_value), 2) AS avg_order_value,
    COUNT(DISTINCT f.customer_unique_id) AS unique_customers,
    ROUND(AVG(f.review_score), 2) AS avg_review_score,
    ROUND(AVG(DATEDIFF(f.order_delivered_date, f.order_purchase_date)), 1) AS avg_delivery_days
FROM fact_orders f
JOIN dim_customers c ON f.customer_unique_id = c.customer_unique_id
WHERE f.order_status = 'delivered'
    AND f.order_delivered_date IS NOT NULL
GROUP BY c.customer_state
ORDER BY total_revenue DESC;

-- Query 7: Cohort Retention Analysis (Fixed)
WITH first_purchase AS (
    SELECT
        customer_unique_id,
        MIN(order_purchase_date) AS first_order_date,
        DATE_FORMAT(MIN(order_purchase_date), '%Y-%m') AS cohort_month
    FROM fact_orders
    WHERE order_status = 'delivered'
    GROUP BY customer_unique_id
),
cohort_data AS (
    SELECT
        f.customer_unique_id,
        fp.cohort_month,
        TIMESTAMPDIFF(MONTH, fp.first_order_date, f.order_purchase_date) AS months_since_first
    FROM fact_orders f
    JOIN first_purchase fp ON f.customer_unique_id = fp.customer_unique_id
    WHERE f.order_status = 'delivered'
)
SELECT
    cohort_month,
    months_since_first,
    COUNT(DISTINCT customer_unique_id) AS customers
FROM cohort_data
WHERE months_since_first BETWEEN 0 AND 6
GROUP BY cohort_month, months_since_first
ORDER BY cohort_month, months_since_first;

SET @ref_date = '2018-09-01';

WITH rfm_base AS (
    SELECT
        customer_unique_id,
        DATEDIFF(@ref_date, MAX(order_purchase_date)) AS recency_days,
        COUNT(DISTINCT order_id) AS frequency,
        ROUND(SUM(payment_value), 2) AS monetary
    FROM fact_orders
    WHERE order_status = 'delivered'
    GROUP BY customer_unique_id
),
rfm_scores AS (
    SELECT
        customer_unique_id,
        recency_days,
        frequency,
        monetary,
        NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,
        NTILE(5) OVER (ORDER BY frequency ASC) AS f_score,
        NTILE(5) OVER (ORDER BY monetary ASC) AS m_score
    FROM rfm_base
),
rfm_segments AS (
    SELECT
        customer_unique_id,
        recency_days,
        frequency,
        monetary,
        r_score,
        f_score,
        m_score,
        ROUND((r_score + f_score + m_score) / 3.0, 2) AS rfm_score,
        CASE
            WHEN r_score >= 4 AND f_score >= 4 THEN 'Champion'
            WHEN r_score >= 3 AND f_score >= 3 THEN 'Loyal'
            WHEN r_score >= 3 AND f_score <= 2 THEN 'Potential Loyalist'
            WHEN r_score <= 2 AND f_score >= 3 THEN 'At Risk'
            WHEN r_score <= 2 AND f_score <= 2 AND m_score >= 3 THEN 'Cant Lose Them'
            ELSE 'Lost'
        END AS segment
    FROM rfm_scores
)
SELECT
    segment,
    COUNT(*) AS customer_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct_of_customers,
    ROUND(AVG(monetary), 2) AS avg_monetary,
    ROUND(AVG(recency_days), 0) AS avg_recency_days,
    ROUND(AVG(frequency), 2) AS avg_frequency
FROM rfm_segments
GROUP BY segment
ORDER BY customer_count DESC;