terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  # 모든 리소스에 붙는 태그. 콘솔에서 이 코드로 만든 것을 구분하고, 정리할 때 찾기 쉽다
  default_tags {
    tags = {
      Project   = "sns"
      ManagedBy = "terraform"
    }
  }
}
