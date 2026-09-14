cd ~/Smoker/development/tools

./build_plan_pipeline.sh \
    --packages-index ~/Smoker/minicpan/modules/02packages.details.txt.gz \
    --prefix pipeline_test50 \
    --target-rows 50 \
    --module-limit 25 \
    --perl-versions 5.38 \
    --max-deps 3 \
    --max-versions 2 \
    --selection-mode ordered \
    --version-sampling spread \
    --pair-mode cross \
    --seed 20260724 \
    --sleep-ms 0