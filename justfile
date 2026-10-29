default:
    @just --list

# Build a Release PureMac.app and install it to /Applications
deploy:
    scripts/deploy-local.sh
