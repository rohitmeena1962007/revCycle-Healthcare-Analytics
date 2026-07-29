-- RevCycle: Healthcare Claim Denial & Revenue-at-Risk Analytics
-- MySQL 8.0+ required for CTEs and window functions.
-- Import dimensions first, then fact_claims.
CREATE DATABASE IF NOT EXISTS revcycle_analytics;
USE revcycle_analytics;

DROP TABLE IF EXISTS fact_claims;
DROP TABLE IF EXISTS dim_procedures;
DROP TABLE IF EXISTS dim_providers;
DROP TABLE IF EXISTS dim_payers;

CREATE TABLE dim_payers (
  payer_id VARCHAR(16) PRIMARY KEY,
  payer_name VARCHAR(120) NOT NULL,
  payer_type VARCHAR(40) NOT NULL,
  timely_filing_limit_days INT NULL,
  prior_auth_strictness DECIMAL(7,5) NULL COMMENT 'Share of payer CPT rules requiring prior authorisation'
);

CREATE TABLE dim_providers (
  provider_id VARCHAR(16) PRIMARY KEY,
  provider_npi VARCHAR(40) NULL,
  provider_specialty VARCHAR(120) NOT NULL,
  facility_type VARCHAR(100) NULL,
  region VARCHAR(100) NULL
);

CREATE TABLE dim_procedures (
  procedure_id VARCHAR(16) PRIMARY KEY,
  cpt_code VARCHAR(30) NOT NULL,
  icd10_primary_code VARCHAR(20) NULL,
  procedure_category VARCHAR(100) NULL,
  requires_prior_auth_flag TINYINT(1) NULL,
  standard_charge_usd DECIMAL(14,2) NULL COMMENT 'Median observed claim amount proxy, not a fee schedule'
);

CREATE TABLE fact_claims (
  claim_id VARCHAR(40) PRIMARY KEY,
  payer_id VARCHAR(16) NOT NULL,
  provider_id VARCHAR(16) NOT NULL,
  procedure_id VARCHAR(16) NOT NULL,
  submission_date DATE NULL,
  claim_amount_usd DECIMAL(14,2) NOT NULL,
  paid_amount_usd DECIMAL(14,2) NULL,
  prior_auth_status VARCHAR(80),
  prior_auth_gap_flag TINYINT(1) NOT NULL,
  doc_completeness_score DECIMAL(8,5) NULL,
  claim_status VARCHAR(40) NOT NULL,
  denial_flag TINYINT(1) NOT NULL,
  x12_835_code VARCHAR(30),
  denial_category VARCHAR(100),
  split_set VARCHAR(20),
  predicted_denial_prob DECIMAL(10,8),
  revenue_at_risk_usd DECIMAL(14,2),
  risk_decile_label VARCHAR(20),
  modifier_present TINYINT(1),
  auth_lead_time_days INT NULL,
  CONSTRAINT fk_claim_payer FOREIGN KEY (payer_id) REFERENCES dim_payers(payer_id),
  CONSTRAINT fk_claim_provider FOREIGN KEY (provider_id) REFERENCES dim_providers(provider_id),
  CONSTRAINT fk_claim_procedure FOREIGN KEY (procedure_id) REFERENCES dim_procedures(procedure_id),
  INDEX idx_claim_denial (denial_flag), INDEX idx_claim_split (split_set), INDEX idx_claim_risk (risk_decile_label)
);

-- 1. Denial rate and modelled revenue at risk by payer type.
WITH payer_risk AS (
 SELECT p.payer_type, COUNT(*) total_claims, SUM(f.denial_flag) denied_claims,
        ROUND(100*AVG(f.denial_flag),2) denial_rate_pct,
        ROUND(SUM(f.revenue_at_risk_usd),2) revenue_at_risk_usd
 FROM fact_claims f JOIN dim_payers p ON f.payer_id=p.payer_id
 GROUP BY p.payer_type
)
SELECT *, DENSE_RANK() OVER (ORDER BY denial_rate_pct DESC) AS denial_rate_rank
FROM payer_risk ORDER BY denial_rate_rank;

-- 2. Compare provider specialties and rank by revenue at risk.
WITH specialty_risk AS (
 SELECT pr.provider_specialty, COUNT(*) total_claims,
        ROUND(100*AVG(f.denial_flag),2) denial_rate_pct,
        ROUND(SUM(f.revenue_at_risk_usd),2) revenue_at_risk_usd
 FROM fact_claims f JOIN dim_providers pr ON f.provider_id=pr.provider_id
 GROUP BY pr.provider_specialty
)
SELECT *, ROW_NUMBER() OVER (ORDER BY revenue_at_risk_usd DESC) AS revenue_risk_rank
FROM specialty_risk ORDER BY revenue_risk_rank;

-- 3. Compare CPT codes and show each procedure's share of total modelled risk.
WITH cpt_risk AS (
 SELECT d.cpt_code, COUNT(*) total_claims, SUM(f.denial_flag) denied_claims,
        ROUND(100*AVG(f.denial_flag),2) denial_rate_pct,
        SUM(f.revenue_at_risk_usd) revenue_at_risk_usd
 FROM fact_claims f JOIN dim_procedures d ON f.procedure_id=d.procedure_id
 GROUP BY d.cpt_code
)
SELECT *, ROUND(100*revenue_at_risk_usd/NULLIF(SUM(revenue_at_risk_usd) OVER (),0),2) AS risk_share_pct
FROM cpt_risk ORDER BY revenue_at_risk_usd DESC;

-- 4. Prior-authorisation gap denial rate and revenue risk.
WITH auth_risk AS (
 SELECT prior_auth_gap_flag, COUNT(*) total_claims, SUM(denial_flag) denied_claims,
        ROUND(100*AVG(denial_flag),2) denial_rate_pct,
        ROUND(SUM(revenue_at_risk_usd),2) revenue_at_risk_usd
 FROM fact_claims GROUP BY prior_auth_gap_flag
)
SELECT *, DENSE_RANK() OVER (ORDER BY denial_rate_pct DESC) AS risk_rank
FROM auth_risk ORDER BY risk_rank;

-- 5. Running revenue-at-risk total by model risk decile.
WITH decile_risk AS (
 SELECT CAST(SUBSTRING_INDEX(risk_decile_label,' ',-1) AS UNSIGNED) risk_decile,
        COUNT(*) claim_count, SUM(revenue_at_risk_usd) revenue_at_risk_usd
 FROM fact_claims GROUP BY risk_decile
)
SELECT risk_decile, claim_count, ROUND(revenue_at_risk_usd,2) revenue_at_risk_usd,
       ROUND(SUM(revenue_at_risk_usd) OVER (ORDER BY risk_decile ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),2) cumulative_risk_usd
FROM decile_risk ORDER BY risk_decile;

-- 6. Denial categories and source adjustment-reason codes by payer group.
SELECT p.payer_type, f.denial_category, f.x12_835_code, COUNT(*) denied_claims,
       ROUND(SUM(f.claim_amount_usd),2) denied_billed_amount_usd
FROM fact_claims f JOIN dim_payers p ON f.payer_id=p.payer_id
WHERE f.denial_flag=1
GROUP BY p.payer_type, f.denial_category, f.x12_835_code
ORDER BY denied_claims DESC;
