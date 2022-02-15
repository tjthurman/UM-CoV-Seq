# Python env setup
import os
import re
import csv
import sys
from datetime import datetime

start_time = datetime.now()

#################
##   GLOBALS   ##
################# 

# Mostly pulled from config file

# The name of the batch based on the MiSeq run ID found in the sample file. Should also be present
BATCH_NAME = config["batch"]
# Batch 1, received 06.10.2021: V3P67 : runtime with 20 cores: 2913.04 seconds (49 mins)
# Batch 2, received 07.15.2021: V4R1  : runtime with 20 cores: 2201.23 seconds (37 mins)


# The sample file with barcods, UMGC IDs, data source, and MiSeq run ID.
SAMPLE_FILE = config["sample_file"]

# List the directory containing subdirectories for all sequence batches. The exact directory for this
# batch will be determined by the BATCH_NAME.
BASE_DATA_FOLDER = config["base_data_folder"]

# List the reference genome you want to map to:
REF = config["ref_genome"]

# List the GFF file you want to use:
GFF = config["ref_gff"]

BASE_BATCH_DIR = os.path.normpath(os.path.join("results", BATCH_NAME))

###############
##   SETUP   ##
############### 

# Get the raw data folder based on the current batch name
indirs = os.listdir(BASE_DATA_FOLDER)
RAW_DATA_FOLDER = "unassigned"
for indir in indirs:
    if BATCH_NAME in indir:
        RAW_DATA_FOLDER = os.path.join(BASE_DATA_FOLDER, indir)

# Raise a sensible error if the folder doesn't exist
if RAW_DATA_FOLDER == "unassigned":
    raise OSError("Folder matching given batch name not found in base_data_folder")

# Pull all sample files from the raw data folder
# get filenames of the individual fastas
fasta_fullpath = []
samples = []
for root, dirs, files in os.walk(RAW_DATA_FOLDER):
    for name in files:
        if re.search("_S\d+_L\d+_R[12]_001.fastq.gz$", name):
            samples.append(re.sub("_S\d+_L\d+_R[12]_001.fastq.gz$", "", name))
            fasta_fullpath.append(os.path.join(root, name))

# Get unique sample IDs
samples = list(set(samples))
samples.sort()

# Can comment/uncomment the below line for testing,
# to run pipeline on just the first two samples. 
# samples = samples[1:3]

# Get filename for the BWA genome index
index_path= REF + ".amb"


######################
## HELPER FUNCTIONS ##
######################

# At the very start, need to match each
# sample ID back to its fastq files.
# This assumes that each sample only has one set of sequence files in a given folder. 
def get_R1_for_sample(wildcards):
    outfile = "file_not_found.txt"
    for filename in fasta_fullpath:
        if re.search(wildcards.sample, filename):
            if re.search("R1", filename):
                outfile = filename
    return outfile

def get_R2_for_sample(wildcards):
    outfile = "file_not_found.txt"
    for filename in fasta_fullpath:
        if re.search(wildcards.sample, filename):
            if re.search("R2", filename):
                outfile = filename
    return outfile

# A function to create a readgroup for BWA from the sample, lane, and run info
def make_RG(wildcards):
    for filename in fasta_fullpath:
        if re.search(wildcards.sample, filename):
            if re.search("R1", filename):
                basename = os.path.basename(filename)
    # Extract sample ID, lane, and run (seq1,seq2, seq3) from input
    sample_ID = basename.split("_")[0]
    sample_num = basename.split("_")[1]
    lane = basename.split("_")[2]
    # Assemble the RG header. Fields:
    # ID: Individual sample ID plus sample number
    # LB: library, sample + "lib1"
    # PL: platform, ILLUMINA
    # SM: sample, sample
    # PU: platform unit, run + lane + sample
    rg_out = "@RG\\tID:" + sample_ID + sample_num + "\\tLB:" + sample_ID + "\\tPL:ILLUMINA" + "\\tSM:" + sample_ID
    return rg_out

# A short function to add the batch directory in front of 
# subdirectory paths for inputs/outputs/params
# isolates results between sequencing batchs/pipeline runs
def bd(filepath):
    return os.path.normpath(os.path.join("results", BATCH_NAME, filepath))


####################
## PIPELINE START ##
####################
localrules: all

# Onstart and onsuccess, make a log files and copy the snakefile that was used
# into the results directory for posterity
pipeline_log_file = bd("logs/pipeline_log.tsv")
onstart:
    os.makedirs(os.path.dirname(pipeline_log_file), exist_ok=True)
    with open(pipeline_log_file, 'w') as tsvfile:
        writer = csv.writer(tsvfile, delimiter='\t')
        writer.writerow(["Raw data folder used:", RAW_DATA_FOLDER])
        writer.writerow(["Reference genome used:", REF])
        writer.writerow(["GFF file used:", GFF])
        writer.writerow(["Start time:", start_time.strftime("%B %d, %Y: %H:%M:%S")])
        

onsuccess:
    smk_copy_command = 'cp pipe_reads_to_lineages.smk ' + str(bd("snakefile_used_copy.smk"))
    end_time = datetime.now()
    elapsed_time = end_time - start_time
    os.popen(smk_copy_command) 
    with open(pipeline_log_file, 'a') as tsvfile:
        writer = csv.writer(tsvfile, delimiter='\t')
        writer.writerow(["End time:", end_time.strftime("%B %d, %Y: %H:%M:%S")])
        writer.writerow(["Elapsed time:", str(elapsed_time)])
        writer.writerow(["Copy of snakefile used stored at:", str(bd("snakefile_used_copy.smk"))])

# all: The rule that looks for the final desired output files to initiate running all rules to generate those files.
rule all:
    input:
        bd("results/multiqc/multiqc_report_trimming.html"), # QC report on trimming
        bd(BATCH_NAME + "-summary.csv"), # Final summary of the rest of the results
        bd("gisaid/gisaid.fa") # The fasta file to upload to gisaid with UMGC samples IDs instead of barcodes


## trim_raw_reads : remove adaptors and low-quality bases
# Uses fastp. Options:
# -m Merge mode: merge overlapping read pairs which overlap
# -c Correct mismatched bases in the merged region
# Using default parameters for merge and correction
# --detect_adapter_for_pe Auto-detects possible adaptor sequences for removal
# --cut_front Do a sliding window analysis from the 5' end, cut read when quality falls below thresh
# --cut_front_window_size Window size of 5 for sliding window 
# --cut_front_mean_quality Mean quality of 20 for sliding window
# -l 25 Minimum length of 25 BP for the read
# -w Number of cores
# -h, -j Name of report HTML and JSON  output reports
rule trim_and_merge_raw_reads:
    input:
        raw_r1=get_R1_for_sample,
        raw_r2=get_R2_for_sample
    output:
        trim_merged= bd("processed_reads/trimmed/{sample}.merged.fq.gz"),
        trim_r1_pair= bd("processed_reads/trimmed/{sample}.nomerge.pair.R1.fq.gz"),
        trim_r2_pair= bd("processed_reads/trimmed/{sample}.nomerge.pair.R2.fq.gz"),
        trim_r1_nopair= bd("processed_reads/trimmed/{sample}.nopair.R1.fq.gz"),
        trim_r2_nopair= bd("processed_reads/trimmed/{sample}.nopair.R2.fq.gz"),
        rep_html= bd("logs/fastp/{sample}_trim_fastp.html"),
        rep_json= bd("logs/fastp/{sample}_trim_fastp.json")
    resources:
        cpus = 1
    log:
        bd("logs/fastp/{sample}_trim_log.txt")
    shell:
        """
        fastp -i {input.raw_r1} -I {input.raw_r2} -m --merged_out {output.trim_merged} --out1 {output.trim_r1_pair} --out2 {output.trim_r2_pair} --unpaired1 {output.trim_r1_nopair} --unpaired2 {output.trim_r2_nopair} --detect_adapter_for_pe --cut_front --cut_front_window_size 5 --cut_front_mean_quality 20 -l 25 -j {output.rep_json} -h {output.rep_html} -w $SLURM_CPUS_PER_TASK 2> {log}
        """


# The snakemake linter prefers that, for rules like this
# where we base directories or basenames in as parameters,
# that they be generated through lambda functions from the inputs and/or outputs,
# Insted of hard coding.
# E.g., for this rule here, would use:
    # params:
    #     dir_in = lambda w, input: os.path.split(os.path.splitext(input[0])[0])[0],
    #     dir_out = lambda w, output: os.path.split(os.path.splitext(output[0])[0])[0]
# I think this is kinda dumb and unreadable, just gonna leave the hard coding.
# But, can leave this comment here as an example in case we want to 
# address this in the future. 

## multiqc_trim_reports: collate fastp trimming reports
rule multiqc_trim_reports:
    input:
        expand(bd("logs/fastp/{sample}_trim_fastp.json"), sample = samples)
    output:
        bd("results/multiqc/multiqc_report_trimming.html")
    params:
        dir_in = bd("logs/fastp"),
        dir_out = bd("results/multiqc")
    log:
        bd("logs/multiqc/multiqc_trim_reports.log")
    shell:
        """
        multiqc -f {params.dir_in} -o {params.dir_out} -n multiqc_report_trimming.html > {log} 2>&1
        """

## index_ref: index genome for BWA
# Index the reference genome, if it isn't already
rule index_ref:
    input:
        REF
    output:
        multiext(REF, ".amb", ".ann", ".bwt", ".pac", ".sa")
    log:
        bd("logs/index_ref.log")  
    shell:
        """
        bwa index {input} > {log} 2>&1
        """
# GWCT- multiext isn't working anymore??
# TJT- not sure if this is a version thing? Seems to work fine for me, 
# on version 6.4.1 and 6.6.0

## map_merged_reads: map trimmed, merged reads to reference
#   BWA mem algorithm. Settings:
#   -M Mark shorter split hits as secondary (for Picard compatibility).
#   -t number of threads
#   -R read group, added through lambda function
#   then uses samtools view and samtools sort to convert to bam and sort
#   samtools view options:
#   -b output in bam format
rule map_merged_reads:
    input:
        reads=bd("processed_reads/trimmed/{sample}.merged.fq.gz"),
        genome=REF,
        genome_index=index_path
    output:
        bd("processed_reads/mapped/{sample}.merged.sorted.bam")
    params:
        basename=bd("processed_reads/mapped/{sample}"),
        read_group=make_RG
    log:
        bd("logs/mapping/{sample}_merged.log")
    resources:
        cpus=2
    shell:
        """
        # Run bwa mem, pipe to samtools view to convert to bam, pipe to samtools sort
        bwa mem -M -t $SLURM_CPUS_PER_TASK -R '{params.read_group}' {input.genome} {input.reads} 2> {log} | samtools view -b - 2>> {log} | samtools sort - -o {output} 2>> {log}
        """

# # map_unmerged_pairs: map trimmed, not merged, paired reads to reference
#   BWA mem algorithm. Settings:
#   -M Mark shorter split hits as secondary (for Picard compatibility).
#   -t number of threads
#   -R read group, added through lambda function
#   then uses samtools view and samtools sort to convert to bam and sort
#   samtools view options:
#   -b output in bam format
rule map_unmerged_pairs:
    input:
        reads_forward=bd("processed_reads/trimmed/{sample}.nomerge.pair.R1.fq.gz"),
        reads_reverse=bd("processed_reads/trimmed/{sample}.nomerge.pair.R2.fq.gz"),
        genome=REF,
        genome_index=index_path
    output:
        bd("processed_reads/mapped/{sample}.nomerge.paired.sorted.bam")
    params:
        basename=bd("processed_reads/mapped/{sample}"),
        read_group=make_RG
    log:
        bd("logs/mapping/{sample}_nomerge_paired.log")
    resources:
        cpus=2
    shell:
        """
        # Run bwa mem, pipe to samtools view to convert to bam, pipe to samtools sort 
        bwa mem -M -t $SLURM_CPUS_PER_TASK -R '{params.read_group}' {input.genome} {input.reads_forward} {input.reads_reverse} 2> {log} | samtools view -b - 2>> {log} | samtools sort - -o {output} 2>> {log}
        """

## map_unmerged_unpaired: map trimmed, unmerged, unpaired reads to reference
#   BWA mem algorithm. Settings:
#   -M Mark shorter split hits as secondary (for Picard compatibility).
#   -t number of threads
#   -R read group, added through lambda function
#   then uses samtools view and samtools sort to convert to bam and sort
#   samtools view options:
#   -b output in bam format
rule map_unmerged_unpaired:
    input:
        reads_forward=bd("processed_reads/trimmed/{sample}.nopair.R1.fq.gz"),
        reads_reverse=bd("processed_reads/trimmed/{sample}.nopair.R2.fq.gz"),
        genome=REF,
        genome_index=index_path
    output:
        mapped_forward = bd("processed_reads/mapped/{sample}.nopair.R1.sorted.bam"),
        mapped_reverse = bd("processed_reads/mapped/{sample}.nopair.R2.sorted.bam")
    params:
        basename=bd("processed_reads/mapped/{sample}"),
        read_group=make_RG
    log:
        forward=bd("logs/mapping/{sample}_nopair_R1.log"),
        rev=bd("logs/mapping/{sample}_nopair_R2.log")
    resources:
        cpus=2
    shell:
        """
        # Run bwa mem, pipe to samtools view to convert to bam, save as a tmp.bam
        # Read 1
        bwa mem -M -t $SLURM_CPUS_PER_TASK -R '{params.read_group}' {input.genome} {input.reads_forward} 2> {log.forward} | samtools view -b - 2>> {log.forward} | samtools sort - -o {output.mapped_forward} 2>> {log.forward}

        # Read 2
        bwa mem -M -t $SLURM_CPUS_PER_TASK -R '{params.read_group}' {input.genome} {input.reads_reverse} 2> {log.rev} | samtools view -b - 2>> {log.rev} | samtools sort - -o {output.mapped_reverse} 2>> {log.rev}
        """

## merge_bams_by_sample : merge bam files by sample and run
# merges bams across the 4 types of mapped reads (assembled, paired unassembled, and unpaired SEs)
# for a given sample/lane/sequencing run combination
# use samtools merge, -t is threads
# -c merges identical readgroup headers, which our files from the same individual should have. 
rule merge_sample_bams:
    input: 
        merged=bd("processed_reads/mapped/{sample}.merged.sorted.bam"),
        unmerged_pair=bd("processed_reads/mapped/{sample}.nomerge.paired.sorted.bam"),
        nopair_fwd=bd("processed_reads/mapped/{sample}.nopair.R1.sorted.bam"),
        nopair_rev=bd("processed_reads/mapped/{sample}.nopair.R2.sorted.bam")
    log:
        bd("logs/merge_bams/{sample}_merge.log")
    resources:
        cpus=4
    output:
        bd("processed_reads/per_sample_bams/{sample}.sorted.bam")
    shell:
        """
        samtools merge -c -t {resources.cpus} {output} {input.merged} {input.unmerged_pair} {input.nopair_fwd} {input.nopair_rev} 2> {log}
        """

## index_raw_bams: index bams
rule index_raw_bams:
    input:
        bd("processed_reads/per_sample_bams/{sample}.sorted.bam")
    output:
        bd("processed_reads/per_sample_bams/{sample}.sorted.bam.bai")
    log:
        bd("logs/index_bams/{sample}.log")
    shell:
        """
        samtools index -b {input} 2> {log}
        """

## qualimap_raw_bam: run qualimap on raw bam file
# default options, only changed number of threads with -nt
rule qualimap_raw_bam:
    input:
        bam=bd("processed_reads/per_sample_bams/{sample}.sorted.bam"),
        bai=bd("processed_reads/per_sample_bams/{sample}.sorted.bam.bai")
    output:
        bd("processed_reads/QC/qualimap/{sample}/qualimapReport.html")
    params:
        out_dir=bd("processed_reads/QC/qualimap/{sample}")
    resources:
        cpus=8
    log:
        bd("logs/qualimap/{sample}.log")
    shell:
        """
        qualimap bamqc -bam {input.bam} -nt $SLURM_CPUS_PER_TASK -outdir {params.out_dir} -outformat html --java-mem-size=4G > {log} 2>&1
        """

## multiqc_raw_bam_report: collate qualimap reports on raw bams
rule multiqc_raw_bam_report:
    input:
        expand(bd("processed_reads/QC/qualimap/{sample}/qualimapReport.html"), sample = samples)
    output:
        bd("results/multiqc/multiqc_report_raw_bams.html"),
        bd("results/multiqc/multiqc_report_raw_bams_data/multiqc_general_stats.txt")
    params:
        dir_in = bd("processed_reads/QC/qualimap"),
        dir_out = bd("results/multiqc")
    log:
        bd("logs/multiqc/multiqc_raw_bam_reports.log")
    shell:
        """
        multiqc -f {params.dir_in} -o {params.dir_out} -n multiqc_report_raw_bams.html > {log} 2>&1
        """


# pileup: Generate pileup files for ivar.
#
# samtools options:
# -aa Output all positions, including unused reference sequences
# -A Count orphans
# -d 0 no max depth limit
# -B disable BAQ computation
# -Q 0 No minimum base quality

rule pileup:
    input:
        sample = bd("processed_reads/per_sample_bams/{sample}.sorted.bam"),
        ref=REF
    output:
        var_pileup = bd("results/pileup/{sample}-var.pileup"),
        cons_pileup = bd("results/pileup/{sample}-cons.pileup")
    log:
        var=bd("logs/pileup/{sample}-var.log"),
        cons=bd("logs/pileup/{sample}-cons.log")
    shell:
        """
        samtools mpileup -aa -A -d 0 -B -Q 0 --reference {input.ref} {input.sample} > {output.var_pileup} 2> {log.var}

        samtools mpileup -aa -A -d 0 -B -Q 0 --reference {input.ref} {input.sample} > {output.cons_pileup} 2> {log.cons}
        """

## mask_pileup: Mask problematic sites from the pileups by converting all mapped bases at those
# positions to the reference base, preventing variants from being called.
rule mask_pileup:
    input:
        var_pileup = bd("results/pileup/{sample}-var.pileup"),
        cons_pileup = bd("results/pileup/{sample}-cons.pileup")       
    output:
        masked_var_pileup = bd("results/pileup/{sample}-var.masked.pileup"),
        masked_cons_pileup = bd("results/pileup/{sample}-cons.masked.pileup")
    log:
        var=bd("logs/mask_pileup/{sample}-var.log"),
        cons=bd("logs/mask_pileup/{sample}-cons.log")
    shell:
        """
        python lib/mask_pileup.py {input.var_pileup} {output.masked_var_pileup} > {log.var} 2>&1
        python lib/mask_pileup.py {input.cons_pileup} {output.masked_cons_pileup} > {log.cons} 2>&1
        """

## ivar_raw_bams: Call variants and make consensus seqs for the raw bams
# samtools mipileup into ivar 
#
# iVar options for variant calling
# -q 20 Min quality 20
# -t 0.03 minimum frequency to call variant
# -m 5 min 5 reads to call variant
#
# iVar Options for consensus:
# -q 20 min quality 20
# -t 0.5 50% of reads needed for calling consensus base
rule ivar_variant_and_consensus:
    input:
        masked_var_pileup = bd("results/pileup/{sample}-var.masked.pileup"),
        masked_cons_pileup = bd("results/pileup/{sample}-cons.masked.pileup"),
        sample = bd("processed_reads/per_sample_bams/{sample}.sorted.bam"),
        ref=REF,
        gff=GFF
    output:
        fa=bd("results/ivar/{sample}.fa"),
        qual=bd("results/ivar/{sample}.qual.txt"),
        variants=bd("results/ivar/{sample}.tsv")
    params:
        basename=bd("results/ivar/{sample}")
    log:
        var=bd("logs/ivar/variant_calling/{sample}.log"),
        cons=bd("logs/ivar/consensus/{sample}.log")
    shell:
        """
        # Call Variants
        cat {input.masked_var_pileup} | ivar variants -p {params.basename} -q 20 -t 0.5 -m 10 -r {input.ref} -g {input.gff} > {log.var} 2>&1

        # Make Consensus sequence
        cat {input.masked_cons_pileup} | ivar consensus -p {params.basename} -q 20 -t 0.5 -m 10 > {log.cons} 2>&1
        """

## gatk_haplotypecaller: Call variants with GATK. Emit all sites (-ERC GVCF) for genotyping
# and masking low quality sites called as ./.
rule gatk_haplotypecaller:
    input:
        sample = bd("processed_reads/per_sample_bams/{sample}.sorted.bam"),
        bai = bd("processed_reads/per_sample_bams/{sample}.sorted.bam.bai"),
        ref = REF
    log:
        hc_log = bd("logs/gatk/{sample}_haplotypecaller.log")
    output:
        gvcf = bd("results/gatk/{sample}.gvcf.gz")
    shell:
        """
        gatk HaplotypeCaller -R {input.ref} -I {input.sample} --sample-ploidy 1 -stand-call-conf 30 --native-pair-hmm-threads 4 -ERC GVCF -O {output.gvcf} > {log.hc_log} 2>&1
        """

## gatk_genotypgvcfs: Genotype the GVCFs from the previous steps and emit all sites to 
# filter/mask low quality sites called as ./.
rule gatk_genotypegvcfs:
    input:
        sample = bd("processed_reads/per_sample_bams/{sample}.sorted.bam"),
        bai = bd("processed_reads/per_sample_bams/{sample}.sorted.bam.bai"),
        gvcf = bd("results/gatk/{sample}.gvcf.gz"),
        ref = REF
    log:
        gt_log = bd("logs/gatk/{sample}_genotypegvcfs.log")
    output:
        vcf = bd("results/gatk/{sample}.vcf.gz")
    shell:
        """
        gatk GenotypeGVCFs -R {input.ref} -V {input.gvcf} -O {output.vcf} --sample-ploidy 1 --include-non-variant-sites > {log.gt_log} 2>&1
        """

## filter_vcfs: Filter variants with bcftools.
# 
# filter options:
# MQ < 30: filter variants with mapping quality less than 30
# FORMAT/DP < 10: filter variants with read depth less than 10. This option seems to most affect agreement between
#                 GATK and ivar pipelines, with a lower threshold here corresponding to more agreement.
# FORMAT/DP > 1200: filter variants with read depth greater than 1200.
# FORMAT/GQ < 20: Filter variants with genotype quality less than 20.
# FORMAT/AD[0:1] / FORMAT/DP < 0.5: Filter variants where the alternate allele makes up fewer than 50% of reads.
# ALT="*": Filter variants where the alt is "*", which means it spans a deletion.
rule filter_vcfs:
    input:
        vcf = bd("results/gatk/{sample}.vcf.gz")
    log:
        gt_log = bd("logs/gatk/{sample}_bcftools_filter.log")
    output:
        fvcf = bd("results/gatk/{sample}.fvcf.gz")
    shell:
        """
        bcftools filter -m+ -e 'MQ < 30.0 || FORMAT/DP < 10 || FORMAT/DP > 1200 || FORMAT/GQ < 20 || FORMAT/AD[0:1] / FORMAT/DP < 0.5 || ALT="*"' -s FILTER --IndelGap 5 -Oz -o {output.fvcf} {input.vcf} > {log.gt_log} 2>&1
        """
    
## mask_vcfs: Mask/filter GATK variants at positions in the problematic sites VCF file.
rule mask_vcfs:
    input:
        fvcf = bd("results/gatk/{sample}.fvcf.gz")
    output:
        mvcf = bd("results/gatk/{sample}.masked.fvcf.gz")
    log:
        bd("logs/mask_vcf/{sample}.log")
    shell:
        """
        python lib/mask_vcf.py {input.fvcf} {output.mvcf} > {log} 2>&1
        """

## bcftools_consensus: Generate the consensus sequences from the GATK variant calls.
rule bcftools_consensus:
    input:
        mvcf = bd("results/gatk/{sample}.masked.fvcf.gz"),
        ref = REF
    log:
        gt_log = bd("logs/gatk/{sample}_bcftools_consensus.log")
    output:
        fa = bd("results/gatk/{sample}.fa"),
        chain = bd("results/gatk/{sample}.chain")
    params:
        prefix = "{sample}_"
    shell:
        """
        tabix -fp vcf {input.mvcf}
        bcftools consensus -f {input.ref} -o {output.fa} -c {output.chain} -e "FILTER!='PASS'" -p {params.prefix} {input.mvcf} > {log.gt_log} 2>&1
        """


## combine_raw_consensus: combine sample fastas into one file each for both ivar and GATK calls.
rule combine_raw_consensus:
    input:
        ivar_fa = expand(bd("results/ivar/{sample}.fa"), sample = samples),
        gatk_fa = expand(bd("results/gatk/{sample}.fa"), sample = samples)
    output:
        ivar_cons = bd("results/ivar/all_samples_consensus.fasta"),
        gatk_cons = bd("results/gatk/all_samples_consensus.fasta")
    params:
        ivar_base_dir = bd("results/ivar/"),
        gatk_base_dir = bd("results/gatk/")
    log:
        ivar=bd("logs/combine_consensus/ivar_consensus.log"),
        gatk=bd("logs/combine_consensus/gatk_consensus.log")
    shell:
        """
        cat {params.ivar_base_dir}/*.fa > {output.ivar_cons} 2> {log.ivar}
        cat {params.gatk_base_dir}/*.fa > {output.gatk_cons} 2> {log.gatk}
        """

## consensus_stats: calculate number of Ns for each sample
rule consensus_stats:
    input:
        ivar_cons = bd("results/ivar/all_samples_consensus.fasta"),
        gatk_cons = bd("results/gatk/all_samples_consensus.fasta")
    output:
        ivar_stats = bd("results/ivar/all_samples_consensus_stats.csv"),
        gatk_stats = bd("results/gatk/all_samples_consensus_stats.csv")
    log:
        ivar=bd("logs/consensus_stats/ivar.log"),
        gatk=bd("logs/consensus_stats/gatk.log")
    shell:
        """
        python lib/consensus_stats.py {input.ivar_cons} ivar {output.ivar_stats} > {log.ivar} 2>&1
        python lib/consensus_stats.py {input.gatk_cons} gatk {output.gatk_stats} > {log.gatk} 2>&1
        """

## pangolin_assign_lineage: assign consensus seqs to lineages
rule pangolin_assign_lineage:
    input:
        ivar_cons = bd("results/ivar/all_samples_consensus.fasta"),
        gatk_cons = bd("results/gatk/all_samples_consensus.fasta")
    output:
        ivar_report = bd("results/ivar-pangolin/lineage_report.csv"),
        gatk_report = bd("results/gatk-pangolin/lineage_report.csv"),
    log:
        ivar_log = bd("logs/ivar_pangolin.log"),
        gatk_log = bd("logs/gatk_pangolin.log")
    params:
        ivar_base_dir = bd("results/ivar-pangolin/"),
        gatk_base_dir = bd("results/gatk-pangolin/")
    shell:
        """
        pangolin --alignment {input.ivar_cons} -o {params.ivar_base_dir} --verbose > {log.ivar_log} 2>&1

        pangolin --alignment {input.gatk_cons} -o {params.gatk_base_dir} --verbose > {log.gatk_log} 2>&1
        """

## nextclade_assign_clade:
rule nextclade_assign_clade:
    input:
        ivar_consensus = bd("results/ivar/all_samples_consensus.fasta"),
        gatk_consensus = bd("results/gatk/all_samples_consensus.fasta"),
        tree = "nextclade-resources/tree.json",
        ref = "nextclade-resources/reference.fasta",
        qc_config = "nextclade-resources/qc.json",
        gff = "nextclade-resources/genemap.gff"
    output:
        ivar_report = bd("results/ivar-nextclade/nextclade_report.tsv"),
        gatk_report = bd("results/gatk-nextclade/nextclade_report.tsv")
    log:
        ivar_log = bd("logs/ivar_nextclade.log"),
        gatk_log = bd("logs/gatk_nextclade.log")
    params:
        ivar_base_dir = bd("results/ivar-nextclade/"),
        gatk_base_dir = bd("results/gatk-nextclade/"),
    shell:
        """
        ./nextclade-1.0.0-alpha.9 -i {input.ivar_consensus} --input-root-seq {input.ref} -a {input.tree} -q {input.qc_config} -g {input.gff} -d {params.ivar_base_dir} --output-tsv {output.ivar_report} > {log.ivar_log} 2>&1

        ./nextclade-1.0.0-alpha.9 -i {input.gatk_consensus} --input-root-seq {input.ref} -a {input.tree} -q {input.qc_config} -g {input.gff} -d {params.gatk_base_dir} --output-tsv {output.gatk_report} > {log.gatk_log} 2>&1
        """

## compile_results: Combine all summary tables and generate main table and GISAID table.
rule compile_results:
    input:
        sample_file = SAMPLE_FILE,
        multiqc = bd("results/multiqc/multiqc_report_raw_bams_data/multiqc_general_stats.txt"),
        vcf = expand(bd("results/gatk/{sample}.masked.fvcf.gz"), sample = samples),
        variants = expand(bd("results/ivar/{sample}.tsv"), sample = samples),
        ivar_stats = bd("results/ivar/all_samples_consensus_stats.csv"),
        gatk_stats = bd("results/gatk/all_samples_consensus_stats.csv"),
        ivar_pangolin = bd("results/ivar-pangolin/lineage_report.csv"),
        gatk_pangolin = bd("results/gatk-pangolin/lineage_report.csv"),
        ivar_nextclade = bd("results/ivar-nextclade/nextclade_report.tsv"),
        gatk_nextclade = bd("results/gatk-nextclade/nextclade_report.tsv")
    output:
        bd(BATCH_NAME + "-summary.csv")
    params:
        batch = BATCH_NAME,
        batch_dir = BASE_BATCH_DIR + "/",
        ivar_dir = bd("results/ivar/"),
        gatk_dir = bd("results/gatk/")
    log:
        bd("logs/compile_results.log")
    shell:
        """
        Rscript lib/compile_results.R {input.sample_file} {params.batch} {params.batch_dir} {input.multiqc} {params.ivar_dir} {params.gatk_dir} {input.ivar_stats} {input.gatk_stats} {input.ivar_pangolin} {input.gatk_pangolin} {input.ivar_nextclade} {input.gatk_nextclade} > {log} 2>&1
        """

## gisaid_seqs: Combine sequences with GISAID headers
rule gisaid_seqs:
    input:
        sample_file = SAMPLE_FILE,
        summary_file = bd(BATCH_NAME + "-summary.csv")
    params:
        batch = BATCH_NAME,
        ivar_dir = bd("results/ivar/")
    output:
        gisaid_file = bd("gisaid/gisaid.fa")
    log:
        bd("logs/gisaid_seq.log")
    shell:
        """
        python lib/gisaid_seq.py {params.ivar_dir} {params.batch} {input.sample_file} {input.summary_file} {output.gisaid_file} > {log} 2>&1
        """
