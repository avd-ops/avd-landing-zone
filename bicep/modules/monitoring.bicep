// Monitoring — Log Analytics, the AVD Insights data collection rule, and the
// alerts an AVD operations team actually pages on.

param location string
param tags object
param baseName string
param logAnalyticsName string
param retentionInDays int
param alertEmailAddresses string[]

module workspace 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: 'law'
  params: {
    name: logAnalyticsName
    location: location
    tags: tags
    skuName: 'PerGB2018'
    dataRetention: retentionInDays
    forceCmkForQuery: false
    features: {
      disableLocalAuth: true
    }
  }
}

// AVD Insights only recognizes DCRs whose name starts with "microsoft-avdi-".
// Counters and event logs follow the Microsoft-published AVD Insights set.
module avdInsightsDcr 'br/public:avm/res/insights/data-collection-rule:0.11.0' = {
  name: 'dcr-avd-insights'
  params: {
    name: 'microsoft-avdi-${baseName}'
    location: location
    tags: tags
    dataCollectionRuleProperties: {
      kind: 'Windows'
      description: 'AVD Insights performance counters and event logs.'
      dataSources: {
        performanceCounters: [
          {
            name: 'perfCounters30s'
            streams: ['Microsoft-Perf']
            samplingFrequencyInSeconds: 30
            counterSpecifiers: [
              '\\LogicalDisk(C:)\\Avg. Disk Queue Length'
              '\\LogicalDisk(C:)\\Current Disk Queue Length'
              '\\Memory\\Available Mbytes'
              '\\Memory\\Page Faults/sec'
              '\\Memory\\Pages/sec'
              '\\Memory\\% Committed Bytes In Use'
              '\\PhysicalDisk(*)\\Avg. Disk Queue Length'
              '\\PhysicalDisk(*)\\Avg. Disk sec/Read'
              '\\PhysicalDisk(*)\\Avg. Disk sec/Transfer'
              '\\PhysicalDisk(*)\\Avg. Disk sec/Write'
              '\\Processor Information(_Total)\\% Processor Time'
              '\\User Input Delay per Process(*)\\Max Input Delay'
              '\\User Input Delay per Session(*)\\Max Input Delay'
              '\\RemoteFX Network(*)\\Current TCP RTT'
              '\\RemoteFX Network(*)\\Current UDP Bandwidth'
            ]
          }
          {
            name: 'perfCounters60s'
            streams: ['Microsoft-Perf']
            samplingFrequencyInSeconds: 60
            counterSpecifiers: [
              '\\LogicalDisk(C:)\\% Free Space'
              '\\LogicalDisk(C:)\\Avg. Disk sec/Transfer'
              '\\Terminal Services(*)\\Active Sessions'
              '\\Terminal Services(*)\\Inactive Sessions'
              '\\Terminal Services(*)\\Total Sessions'
            ]
          }
        ]
        windowsEventLogs: [
          {
            name: 'avdEventLogs'
            streams: ['Microsoft-Event']
            xPathQueries: [
              'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Admin!*[System[(Level=2 or Level=3 or Level=4 or Level=0)]]'
              'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational!*[System[(Level=2 or Level=3 or Level=4 or Level=0)]]'
              'System!*'
              'Microsoft-FSLogix-Apps/Operational!*[System[(Level=2 or Level=3 or Level=4 or Level=0)]]'
              'Application!*[System[(Level=2 or Level=3)]]'
              'Microsoft-FSLogix-Apps/Admin!*[System[(Level=2 or Level=3 or Level=4 or Level=0)]]'
            ]
          }
        ]
      }
      destinations: {
        logAnalytics: [
          {
            name: 'law'
            workspaceResourceId: workspace.outputs.resourceId
          }
        ]
      }
      dataFlows: [
        {
          streams: [
            'Microsoft-Perf'
            'Microsoft-Event'
          ]
          destinations: ['law']
        }
      ]
    }
  }
}

// ---------- Alerting ----------
var hasReceivers = !empty(alertEmailAddresses)

module actionGroup 'br/public:avm/res/insights/action-group:0.8.0' = if (hasReceivers) {
  name: 'action-group'
  params: {
    name: 'ag-${baseName}'
    groupShortName: take('avd${replace(baseName, '-', '')}', 12)
    tags: tags
    emailReceivers: [
      for (email, i) in alertEmailAddresses: {
        name: 'email-${i}'
        emailAddress: email
        useCommonAlertSchema: true
      }
    ]
  }
}

var actionGroupIds = hasReceivers ? [actionGroup!.outputs.resourceId] : []

// Log alerts are created before AVD has written its first rows, so the
// WVD* tables may not exist yet; skip query validation at creation time.
var logAlerts = [
  {
    name: 'session-hosts-unhealthy'
    displayName: 'AVD: session host unhealthy'
    description: 'A running session host is reporting a health state other than Available.'
    severity: 1
    query: '''
WVDAgentHealthStatus
| summarize arg_max(TimeGenerated, *) by SessionHostName
| where Status !in ("Available", "Upgrading")
| project TimeGenerated, SessionHostName, Status, SessionHostHealthCheckResult
'''
  }
  {
    name: 'fslogix-errors'
    displayName: 'AVD: FSLogix profile errors'
    description: 'FSLogix logged errors attaching or using profile containers.'
    severity: 2
    query: '''
Event
| where EventLog startswith "Microsoft-FSLogix-Apps" and EventLevelName == "Error"
| summarize Errors = count() by Computer
'''
  }
  {
    name: 'connection-errors'
    displayName: 'AVD: elevated client connection errors'
    description: 'More than 10 non-service connection errors in the evaluation window.'
    severity: 2
    query: '''
WVDErrors
| where tostring(ServiceError) =~ "false"
| summarize Errors = count() by CodeSymbolic
| where Errors > 10
'''
  }
  // The next three read counters the AVD Insights rule above already collects, so they add no
  // ingestion. Thresholds are the Severity 2 ones of the Azure Monitor Baseline Alerts AVD pattern.
  {
    name: 'host-low-disk'
    displayName: 'AVD: session host low on disk space'
    description: 'A session host has less than 10% free space on C: over the evaluation window.'
    severity: 2
    query: '''
Perf
| where ObjectName == "LogicalDisk" and CounterName == "% Free Space" and InstanceName == "C:"
| summarize FreePercent = avg(CounterValue) by Computer
| where FreePercent < 10
'''
  }
  {
    name: 'host-low-memory'
    displayName: 'AVD: session host low on memory'
    description: 'A session host averaged less than 2 GB of available memory over the evaluation window.'
    severity: 2
    query: '''
Perf
| where ObjectName == "Memory" and CounterName =~ "Available MBytes"
| summarize AvailableMB = avg(CounterValue) by Computer
| where AvailableMB < 2048
'''
  }
  {
    name: 'host-high-cpu'
    displayName: 'AVD: session host CPU saturated'
    description: 'A session host averaged more than 85% CPU over the evaluation window.'
    severity: 2
    query: '''
Perf
| where ObjectName == "Processor Information" and CounterName == "% Processor Time" and InstanceName == "_Total"
| summarize CpuPercent = avg(CounterValue) by Computer
| where CpuPercent > 85
'''
  }
]

resource scheduledQueryAlerts 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = [
  for alert in logAlerts: {
    name: 'alert-${baseName}-${alert.name}'
    location: location
    tags: tags
    properties: {
      displayName: alert.displayName
      description: alert.description
      severity: alert.severity
      enabled: true
      evaluationFrequency: 'PT5M'
      windowSize: 'PT15M'
      scopes: [
        workspace.outputs.resourceId
      ]
      skipQueryValidation: true
      autoMitigate: true
      criteria: {
        allOf: [
          {
            query: alert.query
            timeAggregation: 'Count'
            operator: 'GreaterThan'
            threshold: 0
            failingPeriods: {
              numberOfEvaluationPeriods: 1
              minFailingPeriodsToAlert: 1
            }
          }
        ]
      }
      actions: {
        actionGroups: actionGroupIds
      }
    }
  }
]

resource serviceHealthAlert 'Microsoft.Insights/activityLogAlerts@2023-01-01-preview' = if (hasReceivers) {
  name: 'alert-${baseName}-service-health'
  location: 'global'
  tags: tags
  properties: {
    enabled: true
    description: 'Azure Service Health incidents affecting AVD and its dependencies.'
    scopes: [
      subscription().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'ServiceHealth'
        }
        {
          field: 'properties.impactedServices[*].ServiceName'
          containsAny: [
            'Windows Virtual Desktop'
            'Azure Virtual Desktop'
            'Virtual Machines'
            'Storage'
            'Azure Files'
            'Key Vault'
          ]
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroup!.outputs.resourceId
        }
      ]
    }
  }
}

output logAnalyticsWorkspaceResourceId string = workspace.outputs.resourceId
output avdInsightsDataCollectionRuleResourceId string = avdInsightsDcr.outputs.resourceId
