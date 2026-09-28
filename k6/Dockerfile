# The load generator.
#
# Build context is the REPOSITORY ROOT, not this directory:
#   docker build -f k6/Dockerfile -t k6-custom:local .
#
# The tag is pinned on purpose. An unpinned `grafana/k6` means the tool can
# change under your recorded baselines between runs, which turns a regression
# into a mystery.
FROM grafana/k6:1.3.0

# Copies k6/scripts/ and its lib/ subdirectory into /scripts.
COPY k6/scripts /scripts

WORKDIR /scripts
