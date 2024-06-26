# Runs DECON over the datasets cofigured at [datasets_params_file]
#USAGE: Rscript runDecon.R [decon_params_file] [datasets_params_file] [keepTempFiles]
# keepTempFiles: if true, temp files will not be removed (Default: true)
print(paste("Starting at", startTime <- Sys.time()))
print(getwd())
suppressPackageStartupMessages(library(yaml))
source(if (basename(getwd()) == "optimizers") "../utils/utils.r" else "utils/utils.r") # Load utils functions

#Functions----
# Saves csv file with all failed exons (in a common format)
saveExonFailures <- function(deconFailuresFile, bedFile, bamsFolder, outputFolder){
  # load input data
  listOfsamples <- sub(".bam.bai", "", list.files(bamsFolder, pattern = "*.bai"))
  outputFile <- file.path(outputFolder, "failedROIs.csv")
  failuresData <- read.table(deconFailuresFile, header = T, sep = "\t", stringsAsFactors=F)
  bedData <- read.table(bedFile, header = F, sep = "\t", stringsAsFactors=F)

  # define output dataset
  output <- data.frame(matrix(ncol = 5, nrow = 0))
  colnames(output) <- c("SampleID", "Chr", "Start", "End", "Gene")

  # iterate over failures file to build output data
  for(i in 1:nrow(failuresData)) {
    sampleName <- failuresData[i,"Sample"]
    if (failuresData[i,"Type"] == "Whole sample") {
      # Add all bed lines (all exons failed)
      output <- rbind(output, data.frame(SampleID = sampleName, Chr = bedData[, 1], Start = bedData[, 2], End = bedData[, 3], Gene = bedData[, 4]))
    } else if (failuresData[i,"Type"] == "Whole exon"){
      # Add one line (failed exon) for each sample
      lineNumber <- failuresData[i,"Exon"]
      if (sampleName == "All"){
        lineNumber <- failuresData[i,"Exon"]
        size <- length(listOfsamples)
        output <- rbind(output, data.frame(SampleID = listOfsamples,
                                           Chr = rep(bedData[lineNumber, 1], len = size),
                                           Start = rep(bedData[lineNumber, 2], len = size),
                                           End = rep(bedData[lineNumber, 3], len = size),
                                           Gene = rep(bedData[lineNumber, 4], len = size)))
      } else {
        output <- rbind(output, data.frame(SampleID = sampleName, Chr = bedData[lineNumber, 1], Start = bedData[lineNumber, 2], End = bedData[lineNumber, 3], Gene = bedData[lineNumber, 4]))
      }
    } else
      message("Error: Failure type not recognised")
  }

  # save output file
  write.table(output, outputFile, sep="\t", row.names=FALSE, quote = FALSE)
}


#Get parameters----
## Read args----
args <- commandArgs(TRUE)
print(args)
if(length(args)>0) {
  deconParamsFile <- args[1]
  datasetsParamsFile <- args[2]
  keepTempFiles <- args[3]
} else {
  deconParamsFile <- "deconParams.yaml"
  datasetsParamsFile <- "../../datasets.yaml"
  keepTempFiles <- "true"
}

## Load the parameters file----
deconParams <- yaml.load_file(deconParamsFile)
datasets <- yaml.load_file(datasetsParamsFile)
print(paste("Params for this execution:", list(deconParams)))

# extract decon params
deconFolder <- file.path(deconParams$deconFolder)

# Set decon as working directory. Necessary to make decon packrat work
currentFolder <- getwd()

# Dataset iteration ----
# go over datasets and run decon for those which are active
for (name in names(datasets)) {
  setwd(deconFolder)
  dataset <- datasets[[name]]
  if (dataset$include){
    print(paste("Starting DECoN for", name, "dataset", sep=" "))

    # extract fields
    bamsDir <- file.path(dataset$bams_dir)
    bedFile <- file.path(dataset$bed_file)
    fastaFile <- file.path(dataset$fasta_file)

    # Create output folder
    if (!is.null(deconParams$outputFolder)) {
      if(stringr::str_detect(deconParams$outputFolder, "^./")) deconParams$outputFolder <- stringr::str_sub(deconParams$outputFolder, 3, stringr::str_length(deconParams$outputFolder))
      outputFolder <- file.path(currentFolder, deconParams$outputFolder)
    } else{
      outputFolder <- file.path(currentFolder, "output", paste0("decon-", name))}
    if (is.null(deconParams$execution) || deconParams$execution != "skipPrecalcPhase") {
      unlink(outputFolder, recursive = TRUE);
      dir.create(outputFolder)
    }

    # build input/output file paths
    ouputBams <- file.path(outputFolder, "output.bams")
    ouputRData <- file.path(outputFolder, "output.bams.RData")
    failuresFile <- file.path(outputFolder, "failures");
    calls <- file.path(outputFolder, "calls");

    ## Do pre-calc part of the algorithm----
    if (is.null(deconParams$execution) || deconParams$execution != "skipPrecalcPhase") {
      cmd <- paste("Rscript", "ReadInBams.R", "--bams", bamsDir, "--bed", bedFile, "--fasta", fastaFile, "--out", ouputBams)
      print(cmd); system(cmd)
      print("ReadInBams.R finished");

      if (!is.null(deconParams$execution) && deconParams$execution == "onlyPrecalcPhase") {
        print(paste("DECoN (Only pre-calc phase) for", name, "dataset finished", sep=" "))
        cat("\n\n\n")
        quit()
      }
    } else {  # skipPrecalcPhase mode: read previous results
      print(paste("DECoN Skipping pre-calc phase for", name, "dataset finished", sep=" "))

      # Redefine outputRData taking precalc path
      ouputRData <- file.path(deconParams$precalcFolder, "output.bams.RData")
    }


    ## Call part 2----
    cmd <- paste("Rscript", "IdentifyFailures.R", "--RData", ouputRData, "--mincorr", deconParams$mincorr,
                 "--mincov", deconParams$mincov,  "--out", failuresFile)
    print(cmd); system(cmd)
    print("IdentifyFailures.R finished");


    ## Call part 3----
    cmd <- paste("Rscript makeCNVcalls.R", "--RData", ouputRData, "--transProb",  deconParams$transProb, "--plot None",
                 "--out", calls)
    print(cmd); system(cmd)
    print("makeCNVcalls.R finished");

    # Save results----
    ##GenomicRanges object----
    message("Saving CNV GenomicRanges and Failures results")
    #return to main folder
    setwd(currentFolder)
    saveResultsFileToGR(outputFolder, "calls_all.txt", chrColumn = "Chromosome")
    saveExonFailures(file.path(outputFolder, "failures_Failures.txt"), bedFile, bamsDir, outputFolder)

    print(paste("DECoN for", name, "dataset finished", sep=" "))
    cat("\n\n\n")

    ##Temporary files----
    #Delete temporary files if specified
    if(keepTempFiles == "false"){
      filesAll <- list.files(outputFolder, full.names = TRUE)
      filesToKeep <- c("failedROIs.csv", "grPositives.rds", "cnvs_summary.tsv", "cnvFounds.csv", "cnvFounds.txt", "all_cnv_calls.txt", "calls_all.txt", "failures_Failures.txt", "cnv_calls.tsv")
      filesToRemove <- list(filesAll[!(filesAll %in% grep(paste(filesToKeep, collapse = "|"), filesAll, value = TRUE))])
      do.call(unlink, filesToRemove)
    }
  }
}

print(paste("Finishing at", endTime <- Sys.time()))
cat("\nElapsed time:")
print(endTime - startTime)
