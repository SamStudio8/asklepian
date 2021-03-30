#!/usr/bin/bash

# Activate env
eval "$(conda shell.bash hook)"
conda activate samstudio8
source ~/.ocarina
set -euo pipefail

# Init outdir
cd $ASKLEPIAN_DIR
DATESTAMP=${ELAN_DATE} # set by mqtt wrapper
OUTDIR="$ASKLEPIAN_OUTDIR/$DATESTAMP"
mkdir -p $OUTDIR

# Get best ref for each central_sample_id
# TODO There is no need to do this de novo but we do so here for simplicity. We would do well to replace this as it will likely become quite slow, especially with IO perf on login node.
#      We can work toward some future system where Majora keeps a "symlink" to the best QC pag for a PAG Group.
# NOTE samstudio8 2021-01-29
#      Indeed this has become a little slow. In the interim, I have now made I
#      possible to query for consensus metrics directly from Ocarina rather than
#      indivudally hitting each QC file on the FS. We also use the consensus
#      matched FASTA to write out sequences, saving considerable time.
#        We also mark sequences in the paired.ls file to indicate if the best
#      sequence has changed today (1) or not (0). This will allow later functions
#      to decide whether or not to re-process the artifacts (e.g. for variants).
ocarina --oauth --env get pag --test-name 'cog-uk-elan-minimal-qc' --pass --task-wait --task-wait-attempts 60 \
    --ofield consensus.pc_masked pc_masked 'XXX' \
    --ofield consensus.pc_acgt pc_acgt 'XXX' \
    --ofield consensus.current_path fasta_path 'XXX' \
    --ofield consensus.num_bases num_bases 0 \
    --ofield central_sample_id central_sample_id 'XXX' \
    --ofield run_name run_name 'XXX' \
    --ofield published_name published_name 'XXX' \
    --ofield published_date published_date 'XXX' \
    --ofield adm1 adm1 'XXX' \
    --ofield collection_pillar collection_pillar '' \
    --ofield collection_date collection_date '' \
    --ofield received_date received_date '' > $OUTDIR/consensus.metrics.tsv
python get_best_ref.py --fasta $COG_PUBLISHED_DIR/latest/elan.consensus.matched.fasta --metrics $OUTDIR/consensus.metrics.tsv --latest $ASKLEPIAN_PUBDIR/latest/best_refs.paired.ls --out-ls $OUTDIR/best_refs.paired.ls > $OUTDIR/best_refs.paired.fasta 2> $OUTDIR/best_refs.log

################################################################################
# This stanza emulates the key first rules from phylopipe 1_preprocess_uk
# that are required to generate a naive insertion-unaware MSA.
# We perform them here independently while we work to stabilise phylopipe.
# See https://github.com/COG-UK/grapevine/blob/master/rules/1_preprocess_uk.smk

# uk_minimap2_to_reference
minimap2 -t 24 -a -x asm5 $WUHAN_FP $OUTDIR/best_refs.paired.fasta > $OUTDIR/output.sam 2> $OUTDIR/mm2.log

# uk_full_untrimmed_alignment
datafunk sam_2_fasta -s $OUTDIR/output.sam -r $WUHAN_FP -o $OUTDIR/naive_msa.fasta 2> $OUTDIR/dfunk.log

# The 'naive' MSA here is not filtered on person-level identifiers, neither does
# it consider any filtering or masking. We use it in the knowledge that some
# of the variants may be dirty. Outside of its use for the full variant table here,
# it should not be considered an equivalent drop-in for the phylopipe MSA.
################################################################################

# Make and push genome table
python make_genomes_table.py --fasta $OUTDIR/best_refs.paired.fasta --meta $COG_PUBLISHED_DIR/majora.latest.metadata.matched.tsv > $OUTDIR/genome_table_$DATESTAMP.csv
python make_genomes_table_v2.py --fasta $OUTDIR/best_refs.paired.fasta --meta $OUTDIR/consensus.metrics.tsv --best-ls $OUTDIR/best_refs.paired.ls > $OUTDIR/test_v2_genome_table_$DATESTAMP.csv
python upload_azure.py -c genomics -f $OUTDIR/genome_table_$DATESTAMP.csv
python upload_azure.py -c genomics -f $OUTDIR/test_v2_genome_table_$DATESTAMP.csv

# Make and push variant table
python make_variants_table.py --ref $WUHAN_FP --msa $OUTDIR/naive_msa.fasta > $OUTDIR/variant_table_$DATESTAMP.csv
python upload_azure.py -c genomics -f $OUTDIR/variant_table_$DATESTAMP.csv

# Make and push long and wide depth (position) tables
#python make_depth_table.py

# Clean up
rm $OUTDIR/best_refs.paired.fasta
rm $OUTDIR/output.sam
rm $OUTDIR/genome_table_$DATESTAMP.csv
rm $OUTDIR/test_v2_genome_table_$DATESTAMP.csv

# Push artifacts
PUBDIR="$ASKLEPIAN_PUBDIR/$DATESTAMP"
mkdir -p $PUBDIR
mv $OUTDIR/naive_msa.fasta $PUBDIR
mv $OUTDIR/variant_table_$DATESTAMP.csv $PUBDIR/naive_variant_table.csv
mv $OUTDIR/best_refs.paired.ls $PUBDIR
ln -fn -s $PUBDIR $ASKLEPIAN_PUBDIR/latest

