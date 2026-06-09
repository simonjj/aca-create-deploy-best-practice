using './main.bicep'

param namePrefix = 'academo'
param appName = 'api'
param targetPort = 8080
param envVars = [
  {
    name: 'APP_GREETING'
    value: 'hello from infra'
  }
]
