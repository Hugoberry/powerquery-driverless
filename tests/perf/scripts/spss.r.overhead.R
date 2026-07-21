.libPaths(c(Sys.getenv('R_LIBS_USER'), .libPaths()))
library(haven)
result <- data.frame(v = 0)
