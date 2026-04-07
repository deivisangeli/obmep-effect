################################################################################

## Consolidar CO_PESSOA_FISICA instaveis via union-find

################################################################################

rm(list = ls()); gc()

suppressPackageStartupMessages({
  library(data.table)
  library(arrow)
})

################################################################################

## Parametros

################################################################################

input_matches <- "C:/Users/megaj/Globtalent Dropbox/OBMEP/test/sample_test/mock_fuzzy_matches_union_find.parquet"
output_id_map <- "C:/Users/megaj/Globtalent Dropbox/OBMEP/test/sample_test/mock_union_find_id_map.parquet"
output_cluster_summary <- "C:/Users/megaj/Globtalent Dropbox/OBMEP/test/sample_test/mock_union_find_cluster_summary.parquet"

################################################################################

## Ler o arquivo de matches

################################################################################

if (!file.exists(input_matches)) {
  stop(sprintf("Arquivo de entrada nao encontrado: %s", input_matches), call. = FALSE)
}

if (grepl("\\.parquet$", input_matches, ignore.case = TRUE)) {
  matches <- as.data.table(read_parquet(input_matches))
} else if (grepl("\\.csv(\\.gz)?$", input_matches, ignore.case = TRUE)) {
  matches <- fread(input_matches, na.strings = c("", "NA", "NULL"))
} else {
  stop("O script aceita apenas arquivos .parquet, .csv ou .csv.gz.", call. = FALSE)
}

if (!all(c("CO_PESSOA_FISICA_1", "CO_PESSOA_FISICA_2") %chin% names(matches))) {
  stop(
    "O arquivo precisa ter as colunas CO_PESSOA_FISICA_1 e CO_PESSOA_FISICA_2.",
    call. = FALSE
  )
}

################################################################################

## Padronizar as duas colunas de ID para texto

################################################################################

if (is.numeric(matches$CO_PESSOA_FISICA_1)) {
  matches[, CO_PESSOA_FISICA_1 := format(CO_PESSOA_FISICA_1, scientific = FALSE, trim = TRUE)]
} else {
  matches[, CO_PESSOA_FISICA_1 := as.character(CO_PESSOA_FISICA_1)]
}

if (is.numeric(matches$CO_PESSOA_FISICA_2)) {
  matches[, CO_PESSOA_FISICA_2 := format(CO_PESSOA_FISICA_2, scientific = FALSE, trim = TRUE)]
} else {
  matches[, CO_PESSOA_FISICA_2 := as.character(CO_PESSOA_FISICA_2)]
}

matches[, CO_PESSOA_FISICA_1 := trimws(sub("\\.0+$", "", CO_PESSOA_FISICA_1))]
matches[, CO_PESSOA_FISICA_2 := trimws(sub("\\.0+$", "", CO_PESSOA_FISICA_2))]
matches[CO_PESSOA_FISICA_1 %chin% c("", "NA", "NULL"), CO_PESSOA_FISICA_1 := NA_character_]
matches[CO_PESSOA_FISICA_2 %chin% c("", "NA", "NULL"), CO_PESSOA_FISICA_2 := NA_character_]

################################################################################

## Manter apenas pares validos e remover duplicatas direcionadas

################################################################################

edges <- matches[
  !is.na(CO_PESSOA_FISICA_1) &
    !is.na(CO_PESSOA_FISICA_2) &
    CO_PESSOA_FISICA_1 != CO_PESSOA_FISICA_2,
  .(CO_PESSOA_FISICA_1, CO_PESSOA_FISICA_2)
]

if (!nrow(edges)) {
  id_map_vazio <- data.table(
    CO_PESSOA_FISICA = character(),
    canonical_id = character(),
    cluster_id = character(),
    cluster_size = integer()
  )

  if (grepl("\\.parquet$", output_id_map, ignore.case = TRUE)) {
    dir.create(dirname(output_id_map), recursive = TRUE, showWarnings = FALSE)
    write_parquet(id_map_vazio, sink = output_id_map)
  } else {
    dir.create(dirname(output_id_map), recursive = TRUE, showWarnings = FALSE)
    fwrite(id_map_vazio, output_id_map)
  }

  if (nzchar(output_cluster_summary)) {
    cluster_vazio <- data.table(
      cluster_id = character(),
      canonical_id = character(),
      cluster_size = integer(),
      member_ids = character()
    )

    if (grepl("\\.parquet$", output_cluster_summary, ignore.case = TRUE)) {
      dir.create(dirname(output_cluster_summary), recursive = TRUE, showWarnings = FALSE)
      write_parquet(cluster_vazio, sink = output_cluster_summary)
    } else {
      dir.create(dirname(output_cluster_summary), recursive = TRUE, showWarnings = FALSE)
      fwrite(cluster_vazio, output_cluster_summary)
    }
  }

  cat("Nenhum par valido foi encontrado.\n")
  quit(save = "no", status = 0L)
}

edges[, id_num_1 := suppressWarnings(as.numeric(CO_PESSOA_FISICA_1))]
edges[, id_num_2 := suppressWarnings(as.numeric(CO_PESSOA_FISICA_2))]
edges[, first_is_smaller := id_num_1 <= id_num_2]
edges[is.na(first_is_smaller), first_is_smaller := CO_PESSOA_FISICA_1 <= CO_PESSOA_FISICA_2]
edges[, id_a := fifelse(first_is_smaller, CO_PESSOA_FISICA_1, CO_PESSOA_FISICA_2)]
edges[, id_b := fifelse(first_is_smaller, CO_PESSOA_FISICA_2, CO_PESSOA_FISICA_1)]
edges <- unique(edges[, .(id_a, id_b)])

################################################################################

## Criar a tabela de nos do grafo

################################################################################

nodes <- data.table(CO_PESSOA_FISICA = unique(c(edges$id_a, edges$id_b)))
nodes[, id_num := suppressWarnings(as.numeric(CO_PESSOA_FISICA))]
nodes[, id_order := fifelse(is.na(id_num), Inf, id_num)]
setorder(nodes, id_order, CO_PESSOA_FISICA)
nodes[, c("id_num", "id_order") := NULL]
nodes[, node_index := .I]

node_lookup <- copy(nodes)
setkey(node_lookup, CO_PESSOA_FISICA)

edges[node_lookup, idx_a := i.node_index, on = c(id_a = "CO_PESSOA_FISICA")]
edges[node_lookup, idx_b := i.node_index, on = c(id_b = "CO_PESSOA_FISICA")]

################################################################################

## Inicializar o union-find

################################################################################

parent <- seq_len(nrow(nodes))
rank <- integer(nrow(nodes))

find_root <- function(x) {
  root <- x

  while (parent[root] != root) {
    root <- parent[root]
  }

  while (parent[x] != x) {
    next_x <- parent[x]
    parent[x] <<- root
    x <- next_x
  }

  root
}

union_sets <- function(a, b) {
  root_a <- find_root(a)
  root_b <- find_root(b)

  if (root_a == root_b) {
    return(invisible(NULL))
  }

  if (rank[root_a] < rank[root_b]) {
    parent[root_a] <<- root_b
  } else if (rank[root_a] > rank[root_b]) {
    parent[root_b] <<- root_a
  } else {
    parent[root_b] <<- root_a
    rank[root_a] <<- rank[root_a] + 1L
  }

  invisible(NULL)
}

################################################################################

## Unir os IDs que aparecem conectados no dataset de matches

################################################################################

for (i in seq_len(nrow(edges))) {
  union_sets(edges$idx_a[i], edges$idx_b[i])
}

nodes[, root_index := vapply(node_index, find_root, integer(1L))]
nodes[, id_num := suppressWarnings(as.numeric(CO_PESSOA_FISICA))]

################################################################################

## Montar os clusters e escolher a menor ID como canonica

################################################################################

cluster_summary <- nodes[
  ,
  {
    ids_ordenadas <- if (all(!is.na(id_num))) {
      CO_PESSOA_FISICA[order(id_num, CO_PESSOA_FISICA)]
    } else {
      CO_PESSOA_FISICA[order(CO_PESSOA_FISICA)]
    }

    list(
      canonical_id = ids_ordenadas[1L],
      cluster_id = ids_ordenadas[1L],
      cluster_size = .N,
      member_ids = paste(ids_ordenadas, collapse = "|")
    )
  },
  by = root_index
]

################################################################################

## Gerar uma linha por ID com a sua ID canonica

################################################################################

id_map <- merge(
  nodes[, .(CO_PESSOA_FISICA, root_index)],
  cluster_summary,
  by = "root_index",
  all.x = TRUE
)

id_map[, root_index := NULL]
id_map[, id_num := suppressWarnings(as.numeric(CO_PESSOA_FISICA))]
id_map[, canonical_num := suppressWarnings(as.numeric(canonical_id))]
id_map[, id_order := fifelse(is.na(id_num), Inf, id_num)]
id_map[, canonical_order := fifelse(is.na(canonical_num), Inf, canonical_num)]
setorder(id_map, canonical_order, canonical_id, id_order, CO_PESSOA_FISICA)
id_map[, c("id_num", "canonical_num", "id_order", "canonical_order", "member_ids") := NULL]

################################################################################

## Salvar o mapa principal de IDs

################################################################################

dir.create(dirname(output_id_map), recursive = TRUE, showWarnings = FALSE)

if (grepl("\\.parquet$", output_id_map, ignore.case = TRUE)) {
  write_parquet(id_map, sink = output_id_map)
} else {
  fwrite(id_map, output_id_map)
}

################################################################################

## Salvar o resumo por cluster, se o usuario pedir

################################################################################

if (nzchar(output_cluster_summary)) {
  cluster_summary[, root_index := NULL]
  cluster_summary[, canonical_num := suppressWarnings(as.numeric(canonical_id))]
  cluster_summary[, canonical_order := fifelse(is.na(canonical_num), Inf, canonical_num)]
  setorder(cluster_summary, canonical_order, canonical_id)
  cluster_summary[, c("canonical_num", "canonical_order") := NULL]

  dir.create(dirname(output_cluster_summary), recursive = TRUE, showWarnings = FALSE)

  if (grepl("\\.parquet$", output_cluster_summary, ignore.case = TRUE)) {
    write_parquet(cluster_summary, sink = output_cluster_summary)
  } else {
    fwrite(cluster_summary, output_cluster_summary)
  }
}

cat(sprintf("Foram processadas %s arestas unicas e %s IDs.\n", nrow(edges), nrow(nodes)))
