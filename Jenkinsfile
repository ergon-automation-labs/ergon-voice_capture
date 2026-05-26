pipeline {
  agent any

  environment {
    BOT_NAME = 'voice_capture'
    RELEASE_NAME = 'voice_capture_bot'
  }

  stages {
    stage('Download Release') {
      steps {
        script {
          def version = sh(script: "grep 'version:' mix.exs | head -1 | sed 's/.*\"\\([^\"]*\\)\".*/\\1/'", returnStdout: true).trim()
          env.VERSION = version
          sh "gh release download v${version} --pattern '${RELEASE_NAME}-${version}.tar.gz' --dir _build/prod/rel || true"
        }
      }
    }

    stage('Deploy') {
      steps {
        sh 'salt-call state.apply bot_army_voice_capture'
      }
    }
  }

  post {
    failure {
      echo "Deployment of ${RELEASE_NAME} failed"
    }
  }
}