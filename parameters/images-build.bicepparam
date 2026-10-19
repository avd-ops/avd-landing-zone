// Golden image pipeline: one build (build/specs/image-pipeline-spec.md section 5.2).
// scripts/ops/Start-AvdImageBuild.ps1 sets the AVD_IMAGE_* values for each build; the
// defaults only let CI compile this file.

using '../bicep/images/build.bicep'

param namePrefix = 'avdlz'
param buildEnvironment = 'dev'
param version = readEnvironmentVariable('AVD_IMAGE_VERSION', '2026.1004.1')
param sourceImageVersion = readEnvironmentVariable('AVD_IMAGE_SOURCE_VERSION', '26100.1.250101')
param commit = readEnvironmentVariable('AVD_IMAGE_COMMIT', 'unknown')
param runUrl = readEnvironmentVariable('AVD_IMAGE_RUN_URL', '')
param emergency = readEnvironmentVariable('AVD_IMAGE_EMERGENCY', 'false') == 'true'

// One replica in every region an environment uses; ZRS where the region has availability
// zones, LRS where it doesn't (lesson 0001). The default landing zone region, North Central
// US, has no zones. One replica per 20 hosts created at once (spec section 4.2).
param replicaRegions = [
  {
    name: empty(readEnvironmentVariable('AVD_LOCATION', '')) ? 'northcentralus' : readEnvironmentVariable('AVD_LOCATION', '')
    storageAccountType: 'Standard_LRS'
    replicaCount: 1
  }
]
param buildVmSize = 'Standard_D4s_v5'
param buildTimeoutInMinutes = 360
param disconnectedSessionLimitHours = 8
