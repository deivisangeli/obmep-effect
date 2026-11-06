# Discovering High-Precision Job-Title Rules for Finance and Engineering

## Objective

The goal is to use the existing `job_category` classification as a weak supervisory signal to discover interpretable expressions in `title_raw` that are strongly associated with **Finance** or **Engineering**.

The analysis should not begin from a manually defined dictionary of finance or engineering keywords. Instead, candidate expressions should be discovered empirically from the relationship between `title_raw` and `job_category`.

The final objective is to identify statistically supported expressions and combinations of expressions that can later be converted into transparent regex-based classification rules operating directly on `title_raw`.

---

## Input Data

The analysis uses only two variables:

- `title_raw`: the original LinkedIn job title.
- `job_category`: the existing broad occupational classification.

The two target classification problems are:

1. **Finance vs. all other job categories**
2. **Engineering vs. all other job categories**

Each target should be analyzed separately.

---

## 1. Title Normalization

Create a normalized version of `title_raw` while preserving the substantive occupational information contained in the title.

Recommended preprocessing includes:

- Convert text to lowercase.
- Normalize whitespace.
- Standardize punctuation.
- Remove irrelevant punctuation where appropriate.
- Preserve meaningful technical terms and abbreviations.
- Avoid aggressive stemming if it reduces interpretability.
- Keep both the original and normalized title in the analytical dataset.

The normalization procedure should be deterministic and documented.

---

## 2. Discovery and Validation Samples

Before searching for predictive expressions, divide the data into:

- **Discovery sample**
- **Validation sample**

All expression discovery, threshold selection, interaction searches, and model fitting must use only the discovery sample.

The validation sample must remain untouched until candidate expressions and rules have been selected.

This separation is necessary because repeated inspection of the same observations can otherwise lead to overfitting.

If the same normalized title appears multiple times, observations with the same normalized title should preferably remain in the same sample so that identical titles do not appear in both discovery and validation datasets.

---

## 3. Candidate Expression Extraction

Extract interpretable expressions from normalized job titles.

At minimum, consider:

- Unigrams
- Bigrams
- Trigrams
- Four-grams when computationally feasible

Examples include:

- `engineer`
- `mechanical engineer`
- `investment banking`
- `investment banking analyst`

Expressions should be evaluated based on their ability to distinguish the target category from all other categories, rather than simply on how frequently they occur within the target category.

---

## 4. Statistics for Each Expression

For every candidate expression and each target category, calculate the following statistics.

### Support

Number of observations whose normalized title contains the expression.

### Target Support

Number of observations containing the expression that belong to the target category.

### Precision

The conditional probability that an observation belongs to the target category given that the expression appears in the title:

`P(target | expression)`

This is the primary measure of how reliable the expression is as a classification rule.

### Recall / Target Coverage

The proportion of all target-category observations captured by the expression.

A highly precise phrase may still have very low recall if it identifies only a small occupational niche.

### Base Rate

The unconditional share of observations belonging to the target category:

`P(target)`

### Lift

Calculate:

`Lift = P(target | expression) / P(target)`

Lift measures how much more likely the target category becomes after observing the expression.

For example, if Finance represents 10% of all observations but 95% of titles containing `investment banking` belong to Finance, the expression has a lift of 9.5.

### Optional Association Statistics

Additional useful measures may include:

- Log odds ratio
- Regularized log odds ratio
- Z-score for the log odds ratio
- Chi-squared association statistic

These statistics can help distinguish genuinely informative expressions from very rare phrases that happen to have high observed precision.

---

## 5. Minimum-Support Requirements

Do not rank extremely rare expressions highly solely because they have 100% observed precision.

Evaluate several minimum-support thresholds.

For example:

- at least 25 observations
- at least 50 observations
- at least 100 observations
- at least 500 observations

Report how the number and quality of candidate expressions change across these thresholds.

A candidate expression should ideally combine:

- high precision,
- meaningful support,
- substantial lift,
- and useful target coverage.

---

## 6. Single-Expression Results

Produce ranked tables of the strongest individual expressions for Finance and Engineering.

The main table should contain:

| Variable | Description |
|---|---|
| `target` | Finance or Engineering |
| `expression` | unigram, bigram, trigram, or four-gram |
| `n_words` | number of tokens in the expression |
| `support` | number of observations containing the expression |
| `target_support` | target observations containing the expression |
| `precision` | P(target \| expression) |
| `recall` | share of target observations captured |
| `base_rate` | unconditional target probability |
| `lift` | precision divided by base rate |
| `log_odds` | optional association measure |
| `validation_precision` | precision in untouched validation data |
| `validation_support` | support in validation data |

Generate separate ranked outputs emphasizing:

1. Highest precision
2. Highest support among high-precision expressions
3. Highest lift
4. Highest recall among expressions satisfying a minimum precision threshold

---

## 7. Discovery of Expression Combinations

Many job-title terms are ambiguous individually but become highly informative when combined.

For example:

- `analyst`
- `manager`
- `associate`
- `specialist`
- `consultant`

These terms should not automatically become classification rules.

Instead, systematically evaluate combinations such as:

`expression A AND expression B`

The two expressions do not need to be adjacent in the title.

Examples of quantities to calculate include:

- `P(Finance | analyst AND credit)`
- `P(Finance | analyst AND investment)`
- `P(Finance | analyst AND equity)`
- `P(Engineering | engineer AND mechanical)`
- `P(Engineering | engineer AND process)`

For every pair, calculate:

- support,
- precision,
- recall,
- lift,
- precision of expression A alone,
- precision of expression B alone,
- improvement in precision relative to each component.

Prioritize combinations where the joint rule produces a substantial increase in precision.

---

## 8. Negative or Exclusion Expressions

Also identify expressions that substantially reduce the probability of the target category.

These are useful for constructing future exclusion rules.

For example, if `analyst` is moderately associated with Finance but combinations such as:

- `data analyst`
- `marketing analyst`
- `laboratory analyst`

have very low Finance probabilities, these terms can later be used to prevent false positives.

For each candidate exclusion, calculate:

- support,
- target probability,
- change in target probability relative to the parent expression,
- validation-set performance.

This analysis should generate candidate rules of the form:

`expression A AND NOT expression B`

---

## 9. Logistic LASSO as a Feature-Discovery Tool

Fit separate cross-validated logistic LASSO models for:

- Finance vs. non-Finance
- Engineering vs. non-Engineering

Use a sparse document-feature matrix constructed from candidate n-grams.

The purpose of the LASSO is not to create the final classifier. It is a complementary feature-discovery method.

Report:

- strongest positive coefficients,
- strongest negative coefficients,
- coefficient magnitude,
- expression frequency,
- whether the expression was also identified by the univariate analysis.

Expressions that are strongly predictive under both the descriptive statistics and the multivariate LASSO analysis should receive particular attention.

---

## 10. Unique-Title and Position-Weighted Analyses

Because the same `title_raw` may appear many times, report two versions of the analysis.

### Position-Weighted Analysis

Each LinkedIn position counts as one observation.

This answers:

> How accurately would this expression classify positions in the actual dataset?

### Unique-Title Analysis

Each distinct normalized title counts once.

This answers:

> How general is this linguistic rule across distinct title formulations?

Both perspectives are useful.

A phrase may perform extremely well in the position-weighted analysis because it appears in a few very common job titles while performing less well across the long tail of unique titles.

---

## 11. Out-of-Sample Validation

Every candidate expression or combination retained during the discovery stage must be re-evaluated in the untouched validation sample.

For each candidate rule report:

- discovery support,
- discovery precision,
- discovery recall,
- discovery lift,
- validation support,
- validation precision,
- validation recall,
- validation lift.

Also calculate:

`precision_change = validation_precision - discovery_precision`

Large declines in validation precision should flag potentially overfit expressions.

The primary ranking of candidate rules should rely on validation-set performance rather than discovery-set performance.

---

## 12. Candidate Rule Table

The main machine-readable output should contain one row per candidate rule.

Suggested columns:

| Column | Description |
|---|---|
| `target` | Finance or Engineering |
| `expression_1` | primary expression |
| `expression_2` | optional second expression |
| `rule_type` | single, AND, or AND NOT |
| `ngram_length` | size of expression |
| `discovery_support` | support in discovery data |
| `discovery_precision` | precision in discovery data |
| `discovery_recall` | recall in discovery data |
| `discovery_lift` | lift in discovery data |
| `validation_support` | support in validation data |
| `validation_precision` | precision in validation data |
| `validation_recall` | recall in validation data |
| `validation_lift` | lift in validation data |
| `precision_change` | validation minus discovery precision |
| `position_weighted` | indicator for weighting scheme |
| `candidate_regex` | optional regex representation |
| `review_status` | optional manual-review flag |

---

## 13. Aggregate Statistics

For Finance and Engineering separately, report:

- Number of observations
- Number of unique normalized titles
- Target-category base rate
- Number of candidate unigrams
- Number of candidate bigrams
- Number of candidate trigrams
- Number of candidate four-grams
- Number of expressions meeting each minimum-support threshold
- Number of expressions exceeding selected precision thresholds, such as:
  - 90%
  - 95%
  - 97.5%
  - 99%
- Number of high-precision expression combinations
- Number of candidate exclusion expressions
- Share of target positions covered by at least one high-precision rule
- Share of unique target titles covered by at least one high-precision rule

A useful summary table would resemble:

| Target | Precision Threshold | Number of Rules | Position Coverage | Unique-Title Coverage |
|---|---:|---:|---:|---:|
| Finance | 90% | ... | ... | ... |
| Finance | 95% | ... | ... | ... |
| Finance | 99% | ... | ... | ... |
| Engineering | 90% | ... | ... | ... |
| Engineering | 95% | ... | ... | ... |
| Engineering | 99% | ... | ... | ... |

---

## 14. Coverage–Precision Frontier

An important final output should show the trade-off between precision and coverage.

For example, progressively combine candidate rules ranked by validation precision and calculate:

- cumulative number of rules,
- cumulative target coverage,
- cumulative precision,
- cumulative number of classified positions.

This makes it possible to assess questions such as:

> How much of Finance can be classified while maintaining at least 99% precision?

or:

> How much additional coverage is obtained when the minimum acceptable precision falls from 99% to 95%?

Produce this frontier separately for Finance and Engineering.

---

## 15. Error and Ambiguity Reports

Generate lists of titles requiring further inspection.

### High-Frequency Uncovered Titles

The most frequent target-category titles not captured by any high-precision rule.

These titles are the most promising candidates for the next round of rule discovery.

### High-Frequency False Positives

Non-target titles captured by candidate rules.

These are useful for discovering exclusions.

### Ambiguous Expressions

Expressions with substantial support but intermediate target probabilities.

For example, a phrase may have:

`P(Finance | expression) = 0.55`

Such expressions should generally not be used alone but may be useful in combinations.

### Unstable Expressions

Expressions whose precision deteriorates substantially between discovery and validation samples.

These should normally be excluded from the final rule set.

---

## 16. Main Output Files

Save the principal outputs in machine-readable form, preferably Parquet.

Recommended files:

- `finance_candidate_phrases.parquet`
- `engineering_candidate_phrases.parquet`
- `finance_candidate_combinations.parquet`
- `engineering_candidate_combinations.parquet`
- `candidate_exclusions.parquet`
- `lasso_coefficients.parquet`
- `candidate_rules_validation.parquet`
- `coverage_precision_frontier.parquet`
- `uncovered_titles.parquet`
- `false_positive_titles.parquet`

Also generate a concise Markdown summary containing:

- dataset statistics,
- target base rates,
- strongest individual expressions,
- strongest combinations,
- most useful exclusions,
- validation performance,
- coverage–precision trade-offs,
- and recommendations for which expressions should be converted into regex rules.

---

## 17. Interpretation

The existing `job_category` variable should be treated as a **weak supervisory label**, not as an unquestionable gold standard.

Therefore, the statistical results answer:

> Which expressions in `title_raw` most reliably reproduce the occupational distinctions contained in `job_category`?

They do not by themselves establish that the underlying `job_category` classification is substantively correct.

The most useful final product is therefore not a single predictive model, but a compact and transparent set of expressions with known:

- support,
- precision,
- recall,
- lift,
- validation stability,
- and coverage.

These expressions can then be manually reviewed and converted into regex-based rules for direct classification of `title_raw`.
