// Golden image pipeline: the gallery, definition and identities (build/specs/image-pipeline-spec.md).
// Deploy once, after the build environment's landing zone has the build subnets
// (AVD_IMAGE_BUILD_SUBNETS=true). See docs/images.md.

using '../bicep/images/main.bicep'

param namePrefix = 'avdlz'
// The same region as the build environment's landing zone (AVD_LOCATION overrides).
param location = empty(readEnvironmentVariable('AVD_LOCATION', ''))
  ? 'northcentralus'
  : readEnvironmentVariable('AVD_LOCATION', '')
param buildEnvironment = 'dev'
// owner/name of the repository whose image-build workflow signs in (empty = no federated credential yet).
param githubRepository = readEnvironmentVariable('AVD_GITHUB_REPOSITORY', '')
