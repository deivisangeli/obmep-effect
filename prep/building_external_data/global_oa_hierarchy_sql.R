# SQL constants shared by the offline pipeline and its fixtures. No data writes.
# DuckDB Jaro plus an explicit Winkler adjustment: p=.1, prefix<=4, Jaro>.7.
hierarchy_evaluation_sql <- "WITH pairs AS (
 SELECT d.*,u.oa_id,a.alias,a.alias_norm,a.alias_kind,a.name_eligible,
  CASE WHEN d.country_code IS NOT NULL AND d.country_code=c.country_code THEN 1 ELSE 0 END country_match,
  CASE
   WHEN a.name_eligible AND d.raw_norm=a.alias_norm THEN 1
   WHEN CASE WHEN a.name_eligible AND length(a.alias_norm)>=3 AND contains(d.raw_norm,a.alias_norm) THEN
    regexp_matches(d.raw_norm,'(^|[^\\p{L}\\p{N}])'||regexp_escape(a.alias_norm)||'($|[^\\p{L}\\p{N}])') ELSE FALSE END THEN 2
   WHEN CASE WHEN a.alias_kind='acronym' AND length(a.alias_norm)>=3 AND contains(d.raw_norm,a.alias_norm) THEN
    regexp_matches(d.raw_norm,'(^|[^\\p{L}\\p{N}])'||regexp_escape(a.alias_norm)||'($|[^\\p{L}\\p{N}])') AND
    (d.raw_norm=a.alias_norm OR list_contains(d.raw_segments,a.alias_norm) OR
     regexp_matches(d.raw_case,'(^|[^\\p{L}\\p{N}])'||regexp_escape(upper(a.alias_norm))||'($|[^\\p{L}\\p{N}])')) ELSE FALSE END THEN 3
   ELSE NULL END alias_stage,
  CASE WHEN a.name_eligible THEN coalesce(us.jaro,jaro_similarity(d.raw_norm,a.alias_norm)) END jaro,
  least(4,length(d.raw_norm),length(a.alias_norm),
   CASE WHEN substr(d.raw_norm,1,1)<>substr(a.alias_norm,1,1) THEN 0
    WHEN substr(d.raw_norm,2,1)<>substr(a.alias_norm,2,1) THEN 1
    WHEN substr(d.raw_norm,3,1)<>substr(a.alias_norm,3,1) THEN 2
    WHEN substr(d.raw_norm,4,1)<>substr(a.alias_norm,4,1) THEN 3 ELSE 4 END) prefix_length
 FROM decision_batch d CROSS JOIN unnest(d.candidate_ids) u(oa_id)
 JOIN catalog c ON c.oa_id=u.oa_id JOIN aliases a ON a.oa_id=u.oa_id
 LEFT JOIN unicode_scores us ON us.raw_norm=d.raw_norm AND us.alias_norm=a.alias_norm
 WHERE length(d.raw_norm)>0
), scored AS (
 SELECT *,jaro+CASE WHEN jaro>0.7 THEN 0.1*prefix_length*(1-jaro) ELSE 0 END jw FROM pairs
)
SELECT decision_id,oa_id,min(alias_stage) candidate_stage,max(country_match)::INTEGER country_match,
 max(jw) jw_similarity,0.2*max(country_match)+0.8*max(jw) score,
 first(alias ORDER BY alias_stage NULLS LAST,alias_kind,alias) FILTER(WHERE alias_stage IS NOT NULL) stage_alias,
 first(alias_kind ORDER BY alias_stage NULLS LAST,alias_kind,alias) FILTER(WHERE alias_stage IS NOT NULL) stage_alias_kind,
 first(alias ORDER BY jw DESC NULLS LAST,alias_kind,alias) FILTER(WHERE name_eligible) similarity_alias
FROM scored GROUP BY decision_id,oa_id"

hierarchy_decision_sql <- "WITH stage AS (
 SELECT *,coalesce(min(candidate_stage) OVER(PARTITION BY decision_id),4) selection_stage,
  max(score) OVER(PARTITION BY decision_id) maximum_score FROM evaluations
), winners AS (
 SELECT * FROM stage WHERE (selection_stage<4 AND candidate_stage=selection_stage)
  OR (selection_stage=4 AND abs(score-maximum_score)<=1e-12)
), collapsed AS (
 SELECT decision_id,min(selection_stage)::INTEGER selection_stage,
 list(oa_id ORDER BY oa_id) selected_ids,
 list(struct_pack(oa_id:=oa_id,supporting_alias:=CASE WHEN selection_stage=4 THEN similarity_alias ELSE stage_alias END,
  alias_kind:=CASE WHEN selection_stage=4 THEN 'similarity_name' ELSE stage_alias_kind END,
  country_match:=country_match,jw_similarity:=jw_similarity,score:=score) ORDER BY oa_id) selected_evidence
 FROM winners GROUP BY decision_id
)
SELECT d.*,c.selection_stage,c.selected_ids,array_to_string(c.selected_ids,'|') selected_ids_pipe,
 c.selected_evidence,coalesce(len(c.selected_ids),0)::INTEGER selected_count,
 CASE WHEN coalesce(len(d.candidate_ids),0)=0 THEN 'unmatched'
  WHEN coalesce(d.raw_norm,'')='' THEN 'unresolved_blank_raw'
  WHEN len(c.selected_ids)>1 THEN 'tied' WHEN len(c.selected_ids)=1 THEN 'single'
  ELSE 'unresolved_no_name' END selection_status
FROM decision_batch d LEFT JOIN collapsed c USING(decision_id)"

hierarchy_unicode_pairs_sql <- "SELECT DISTINCT d.raw_norm,a.alias_norm
 FROM decision_batch d CROSS JOIN unnest(d.candidate_ids) u(oa_id)
 JOIN aliases a ON a.oa_id=u.oa_id AND a.name_eligible
 WHERE length(d.raw_norm)>0 AND (length(d.raw_norm)<>octet_length(encode(d.raw_norm))
  OR length(a.alias_norm)<>octet_length(encode(a.alias_norm)))"
