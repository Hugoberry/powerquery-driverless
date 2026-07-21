.libPaths(c(Sys.getenv('R_LIBS_USER'), .libPaths()))
library(haven)
result <- data.frame(v = local({ df <- read_sav('__PERF_OUT__'); sum(!is.na(df)) }))
