# Runs GermlineCNVcaller over the datasets cofigured at [datasets_params_file]
#USAGE: Rscript runGermlineCNVcaller.R [GermllineCNVcaller_params_file] [datasets_params_file] [include_temp_files]
print(paste("Starting at", startTime <- Sys.time()))
suppressPackageStartupMessages(library(yaml))
source("utils/utils.r") # Load utils functions
library(dplyr)

# Read args ----
args <- commandArgs(TRUE)
print(args)
if(length(args)>0) {
  paramsFile <- args[1]
  datasetsParamsFile <- args[2]
  includeTempFiles <- args[3]
  evaluateParameters <- args[4]
} else {
  paramsFile <- "params.yaml"
  datasetsParamsFile <- "../../datasets.yaml"
  includeTempFiles <- "true"
}

#Load the parameters file
params <- yaml.load_file(paramsFile)
datasets <- yaml.load_file(datasetsParamsFile)

# print params
print(paste("Params for this execution:", list(params)))
print(paste("Datasets for this execution:", list(datasets)))


#locate the folders and the contig file

picardFolder <- params$picardFolder
condaFolder <- params$condaFolder
singularityFolder <- params$singularityFolder
contigFile <- file.path(params$contigFile)
currentFolder <- getwd()


# Dataset iteration ----

# go over datasets and run germilineCNVcaller for those which are active
for (name in names(datasets)) {
  dataset <- datasets[[name]]
  if (dataset$include){
    print(paste("Starting GermlineCNVcaller for", name, "dataset", sep=" "))

   
    #check if outputfolder exists:

    if (!is.null(params$outputFolder)) {
      if(stringr::str_detect(params$outputFolder, "^./")) params$outputFolder <- stringr::str_sub(params$outputFolder, 3, stringr::str_length(params$outputFolder))
      outputFolder <- file.path(currentFolder, params$outputFolder)
    } else {
      outputFolder <- file.path(getwd(), "output", paste0("germlineCNVcaller-", name))
    }

    unlink(outputFolder, recursive = TRUE);
    dir.create(outputFolder)


    # extract fields
    bamsDir <- file.path(dataset$bams_dir)
    bamFiles <- list.files(bamsDir, pattern = '*.bam$', full.names = TRUE)
    bedFile <- file.path(dataset$bed_file)
    fastaFile <- file.path(dataset$fasta_file)
    fastaDict <- file.path(dataset$fasta_dict)

    #create input files required for running GATK

    # Interval list----
    #create intervals file (.intervals_list) from .bed file
    #interval_list<-paste0(outputFolder,"/list.interval_list")
    interval_list <- ifelse(evaluateParameters=="false",
                            paste0(outputFolder,"/list.interval_list"),
                            paste0(currentFolder, "/evaluate_parameters/germlineCNVcaller/", name, "/preCalculated/IntervalList/list.interval_list"))

    if(!file.exists(interval_list)){
      cmd_interval <- paste0( " java -jar ", picardFolder,
                              " BedToIntervalList",
                              " -I ", bedFile,
                              " -O ", interval_list,
                              " -SD ", fastaDict)

      print(cmd_interval);system(cmd_interval);
    }

    # GATK: Preprocess intervals ----
    preprocessInterval_list <- ifelse(evaluateParameters=="false",
                                      paste0(outputFolder,"/preprocessed_intervals.interval_list"),
                                      paste0(currentFolder, "/evaluate_parameters/germlineCNVcaller/", name, "/preCalculated/IntervalList/preprocessed_intervals.interval_list"))
    

    if(!file.exists(preprocessInterval_list)){
      cmd_preprocessIntervals<-paste0( "apptainer run ",
                                       "-B ", dirname(fastaFile), " ",
                                       singularityFolder,
                                       ' gatk --java-options "-Xmx30G" PreprocessIntervals',
                                       " -R ", fastaFile,
                                       " -L ", interval_list,
                                       " -imr OVERLAPPING_ONLY", 
                                       " -O ", preprocessInterval_list )
      
      print(cmd_preprocessIntervals);system(cmd_preprocessIntervals);
    }
    
    # GATK: Annotate intervals----  
    
    annotatedIntervals_list <- ifelse(evaluateParameters=="false",
                                      paste0(outputFolder,"/annotated_intervals.interval_list"),
                                      paste0(currentFolder, "/evaluate_parameters/germlineCNVcaller/", name, "/preCalculated/IntervalList/annotated_intervals.interval_list"))
    
    
    if(!file.exists(annotatedIntervals_list)){
      cmd_annotateIntervals<-paste0( "apptainer run ",
                                     "-B ", dirname(fastaFile), " ",
                                     singularityFolder,
                                     ' gatk --java-options "-Xmx30G" AnnotateIntervals',
                                     " -R ", fastaFile,
                                     " -L ", preprocessInterval_list,
                                     " -imr OVERLAPPING_ONLY", 
                                     " -O ", annotatedIntervals_list )
      
      print(cmd_annotateIntervals);system(cmd_annotateIntervals);
    }
    
    # GATK: Collect read counts ----
    # Get bam files
    bamFiles <- list.files(bamsDir, pattern = '*.bam$', full.names = TRUE)
    readCountsFolder <- ifelse(evaluateParameters=="false",
                                  file.path(outputFolder, "ReadCounts"),
                                  paste0(currentFolder, "/evaluate_parameters/germlineCNVcaller/", name, "/preCalculated/ReadCounts"))

    if(!dir.exists(readCountsFolder)| dir.exists(readCountsFolder) &&  length(list.files(readCountsFolder))!=length(bamFiles)){
      dir.create(readCountsFolder, showWarnings = FALSE)
      print(paste("Starting at", Sys.time(), "collect Read counts"))
      for (bam in bamFiles){
        print(basename(bam))
        sample_name<-sub(pattern = "(.*)\\..*$", replacement = "\\1", basename(bam))
        cmd_read_counts <- paste0( "apptainer run ",
                                 " -B ", bamsDir, " ",
                                 singularityFolder,
                                 ' gatk --java-options "-Xmx30G" CollectReadCounts',
                                  " -I ", bamsDir,"/",sample_name, ".bam",
                                  " -L ", preprocessInterval_list,
                                  " --interval-merging-rule OVERLAPPING_ONLY",
                                  " -O ", readCountsFolder,"/", sample_name, ".counts.hdf5")
        print(cmd_read_counts);system(cmd_read_counts);
        }
      }


    #GATK: Determine contig ploidy ----
    #merge all hdf5 files forrunning DetermineGermlineContigPloidy
    hdf5s <- list.files(readCountsFolder, pattern = '*.hdf5$', full.names = TRUE)
    all_hdf5_names<- paste(hdf5s, collapse=" -I ")
    
    
    # GATK: Filter intervals----  
    filteredIntervals_list <- ifelse(evaluateParameters=="false",
                                     paste0(outputFolder,"/filtered_intervals.interval_list"),
                                     paste0(currentFolder, "/evaluate_parameters/germlineCNVcaller/", name, "/preCalculated/IntervalList/filtered_intervals.interval_list"))
    
    if(!file.exists(filteredIntervals_list)){
      cmd_filterIntervals_list<-paste0( "apptainer run ",
                                        singularityFolder,
                                        ' gatk --java-options "-Xmx30G" FilterIntervals',
                                        " -L ",preprocessInterval_list,
                                        " -I ", all_hdf5_names,
                                        " --annotated-intervals ", annotatedIntervals_list,
                                        " --interval-merging-rule OVERLAPPING_ONLY",
                                        " -O ", filteredIntervals_list )
      
      print(cmd_filterIntervals_list);system(cmd_filterIntervals_list);
    }

    #GATK: Determine contig ploidy ----

    contigPloidy <- ifelse(evaluateParameters=="false",
                               file.path(outputFolder, "contigPloidy"),
                               paste0(currentFolder, "/evaluate_parameters/germlineCNVcaller/", name, "/preCalculated/contigPloidy"))

    if(!dir.exists(contigPloidy)){
    dir.create(contigPloidy)
    print(paste("Starting at", Sys.time(), "contigPloidy"))
    cmd_det_contig_ploidy <- paste0( "apptainer run ",
                                     singularityFolder,
                                     ' gatk --java-options "-Xmx30G" DetermineGermlineContigPloidy',
                                     " -I ", all_hdf5_names,
                                     " -L ", filteredIntervals_list,
                                     " --interval-merging-rule OVERLAPPING_ONLY",
                                     " --contig-ploidy-priors ", contigFile,
                                     " -O ", contigPloidy,
                                     " --output-prefix contig")

    print(cmd_det_contig_ploidy);system(cmd_det_contig_ploidy);
    }
    
    
    # #GATK: Run GermlineCNVcaller ----
     cnvRaw <- file.path(paste0(outputFolder, "/cnvRaw"))
     if (!file.exists(cnvRaw)){
       dir.create(cnvRaw)
     } else {
       unlink(cnvRaw, recursive = TRUE)
       dir.create(cnvRaw, recursive=TRUE)
     }
     print(paste("Starting at", Sys.time(), "GermlienCNVCaller"))
     cmd_GermlineCNVCaller<- paste0( "apptainer run ",
                                     "-B ", currentFolder, " ",
                                     singularityFolder,
                                     ' gatk --java-options "-Xmx30G" GermlineCNVCaller ',
                                     " --run-mode COHORT",
                                     " -L ", filteredIntervals_list,
                                     " --interval-merging-rule OVERLAPPING_ONLY",
                                     " --annotated-intervals ", annotatedIntervals_list,
                                     " --contig-ploidy-calls ", contigPloidy, "/contig-calls",
                                     " -I ", all_hdf5_names,
                                     " -O ", cnvRaw,
                                     " --output-prefix cohort_run",
                                     #optional parameters
                                      " --p-active ", params$pActive,
                                      " --p-alt ", params$pAlt,
                                      " --sample-psi-scale ", params$samplePsiScale,
                                      " --mapping-error-rate ", params$mappingErrorRate,
                                      " --class-coherence-length ", params$classCoherenceLength,
                                      " --cnv-coherence-length ", params$cnvCoherenceLength,
                                      " --interval-psi-scale ", params$intervalPsiScale,
                                      " --active-class-padding-hybrid-mode ", params$activeClassPaddingHybridMode,
                                      " --adamax-beta-1 ", params$adamaxBeta1,
                                      " --adamax-beta-2 ", params$adamaxBeta2,
                                      " --caller-external-admixing-rate ", params$callerExternalAdmixingRate,
                                      " --caller-internal-admixing-rate ", params$callerInternalAdmixingRate,
                                      " --caller-update-convergence-threshold ", params$callerUpdateConvergenceThreshold,
                                      " --convergence-snr-averaging-window ", params$convergenceSnrAveragingWindow,
                                      " --convergence-snr-countdown-window ", params$convergenceSnrCountdownWindow,
                                      " --convergence-snr-trigger-threshold ", params$convergenceSnrTriggerThreshold,
                                      " --depth-correction-tau ", params$depthCorrectionTau,
                                      " --enable-bias-factors ", params$enableBiasFactors,
                                      " --init-ard-rel-unexplained-variance ", params$initArdRelUnexplainedVariance,
                                      " --learning-rate ", params$learningRate,
                                      " --log-emission-samples-per-round ", params$logEmissionSamplesPerRound,
                                      " --log-emission-sampling-median-rel-error ", params$logEmissionSamplingMedianRelError,
                                      " --log-emission-sampling-rounds ", params$logEmissionSamplingRounds,
                                      " --log-mean-bias-standard-deviation ", params$logMeanBiasStandardDeviation,
                                      #" --interval-merging-rule ", params$intervalMergingRule,
                                      " --interval-set-rule ", params$intervalSetRule,
                                      " --num-samples-copy-ratio-approx ", params$numSamplesCopyRatioApprox,
                                      " --num-thermal-advi-iters ", params$numThermalAdviIters,
                                      " --interval-exclusion-padding ", params$intervalExclusionPaddingG,
                                      " --interval-padding ", params$intervalPaddingG,
                                      " --copy-number-posterior-expectation-mode ", params$copyNumberPosteriorExpectationMode,
                                      " --gc-curve-standard-deviation ", params$gcCurveStandardDeviation,
                                      " --max-bias-factors ", params$maxBiasFactors,
                                      " --max-calling-iters ", params$maxCallingIters,
                                      " --max-advi-iter-first-epoch ", params$maxAdviIterFirstEpoch,
                                      " --max-advi-iter-subsequent-epochs ", params$maxAdviIterSubsequentEpochs,
                                      " --max-training-epochs ", params$maxTrainingEpochs,
                                      " --min-training-epochs ", params$minTrainingEpochs,
                                      " --use-jdk-deflater ", params$useJdkDeflater,
                                      " --use-jdk-inflater ", params$useJdkInflater,
                                      " --disable-annealing ", params$disableAnnealing,
                                      " --disable-caller ", params$disableCaller,
                                      " --disable-sampler ", params$disableSampler
                                     )

     print(cmd_GermlineCNVCaller);system(cmd_GermlineCNVCaller);

    ##GATK: Run PostprocessingGermlineCNVcaller

    cnvProcessed <- file.path(paste0(outputFolder, "/cnvProcessed"))
    if (!file.exists(cnvProcessed)){
      dir.create(cnvProcessed)
    } else {
      unlink(cnvProcessed, recursive = TRUE)
      dir.create(cnvProcessed, recursive=TRUE)
    }

    callsRaw <- list.dirs(path=paste0(cnvRaw,"/cohort_run-calls"),  full.names = TRUE, recursive= FALSE)
    ploidyRaw <- list.dirs(path=paste0(contigPloidy,"/contig-calls"),  full.names = TRUE, recursive= FALSE)
    
    print(paste("Starting at", Sys.time(), "Germline postProcess"))
     for (i in 1:length(callsRaw)){
       cmd_GermlineCNVCaller<- paste0( "apptainer run ",
                                       "-B ", currentFolder, " ",
                                       singularityFolder,
                                       ' gatk --java-options "-Xmx30G" PostprocessGermlineCNVCalls',
                                       " --sample-index ",  i-1,
                                       " --calls-shard-path ",paste0(cnvRaw,"/cohort_run-calls") ,
                                       " --contig-ploidy-calls ", paste0(contigPloidy,"/contig-calls"),
                                       " --model-shard-path ", paste0(cnvRaw,"/cohort_run-model"),
                                       " --output-genotyped-intervals ", cnvProcessed, "/SAMPLE_", i-1   ,"_genotyped_intervals.vcf ",
                                       " --output-genotyped-segments ", cnvProcessed, "/SAMPLE_", i-1  ,"_genotyped_segments.vcf ",
                                       " --output-denoised-copy-ratios ", cnvProcessed, "/SAMPLE_", i-1 ,"_denoised_copy_ratios.tsv",

                                       #optional
                                        " --interval-exclusion-padding ", params$intervalExclusionPaddingPp,
                                        " --interval-padding ", params$intervalPaddingPp

       )
       print(cmd_GermlineCNVCaller);system(cmd_GermlineCNVCaller)
     }


#format them as benchmark desired output



#Put all results in the same file  BOOOOO
     resultsFiles <- list.files(path=cnvProcessed, pattern="_genotyped_segments.vcf$", full.names = TRUE, recursive= TRUE)
     cnvData  <- data.frame()
     for(i in seq_len(length(resultsFiles))){
       vcf <-vcfR::read.vcfR(resultsFiles[i])
       sample.name <- (vcf@gt %>% colnames())[2]
       cnvs_proc <- vcfR::vcfR2tidy(vcf, single_frame = TRUE)$dat %>%
         dplyr::rowwise() %>%
         mutate(sample=sample.name)%>%
         dplyr::filter(ALT != ".") %>%
         dplyr::mutate(copy_number = ifelse(ALT == "<DEL>",  "deletion", ifelse(ALT=="<DUP>","duplication", "")),
                       start = POS %>% as.integer(), end = END %>% as.integer())
       cnvData <- rbind(cnvData, cnvs_proc)

     }

     outputFile <- file.path(outputFolder, "all_cnv_calls.txt")
     write.table(cnvData, file = outputFile, sep='\t', row.names=FALSE, col.names=TRUE, quote=FALSE)

     saveResultsFileToGR(outputFolder, "all_cnv_calls.txt", chrColumn = "CHROM", sampleColumn = "sample",
                         startColumn = "start", endColumn = "end", cnvTypeColumn = "copy_number")

     #Delete temporary files if specified
     if(includeTempFiles == "false"){
       filesAll <- list.files(outputFolder, full.names = TRUE)
       filesToKeep <- c("failedROIs.csv", "grPositives.rds", "cnvs_summary.tsv", "cnvFounds.csv", "cnvFounds.txt", "all_cnv_calls.txt", "calls_all.txt", "failures_Failures.txt", "cnv_calls.tsv")
       filesToRemove <- list(filesAll[!(filesAll %in% grep(paste(filesToKeep, collapse= "|"), filesAll, value=TRUE))])
       do.call(unlink, filesToRemove)
       foldersToRemove <- list.dirs(outputFolder, full.names = TRUE, recursive = FALSE)
       unlink(foldersToRemove, recursive = TRUE)

     }

  }
}




print(paste("Finishing at", endTime <- Sys.time()))
cat("\nElapsed time:")
print(endTime - startTime)

