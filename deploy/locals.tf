locals {
  env_suffix = contains(["production", "integration"], terraform.workspace) ? "" : "-${terraform.workspace}"
  base_name  = "notch2${local.env_suffix}"

  aws_max_retries       = 5
  sqs_max_receive_count = 5
  sqs_message_limit     = contains(["production", "integration"], terraform.workspace) ? 100 : 10
  alarms_sns            = terraform.workspace == "production" ? data.aws_sns_topic.alarms[0].arn : aws_sns_topic.alarms[0].arn

  metrics_namespace         = "Notch2/Router"
  metrics_namespace_preproc = "Notch2/Preprocessor"

  # AWS Comprehend Medical: $0.01 per unit (1 unit = 100 characters).
  scrubber_budget_usd      = terraform.workspace == "production" ? 1000 : 5
  scrubber_cost_per_unit   = 0.01
  scrubber_budget_in_units = local.scrubber_budget_usd / local.scrubber_cost_per_unit

  wazowski = {
    resource_id        = data.aws_rds_cluster.wazowski.cluster_resource_id
    host               = data.aws_rds_cluster.wazowski.endpoint
    user               = "notch2-iam"
    database           = "notch_${terraform.workspace}"
    dial_timeout       = "5s"
    read_timeout       = "10s"
    write_timeout      = "10s"
    conn_max_idle_time = "14m"
  }

  ecsc               = aws_elasticache_serverless_cache.deid.endpoint[0]
  preprocessor_image = "${aws_ecr_repository.notch2.repository_url}:${data.external.preprocessor_hash.result.hash}"
  ecs_env = {
    NOTCH_WORKSPACE          = terraform.workspace
    NOTCH_AWS_MAX_RETRIES    = local.aws_max_retries
    NOTCH_RESTRICTED_BUCKET  = module.bucket["notch-restricted"].name
    NOTCH_ELASTIC_CACHE_ADDR = "${local.ecsc.address}:${local.ecsc.port}"
    NOTCH_METRICS_NAMESPACE  = local.metrics_namespace_preproc
    NOTCH_SQS_QUEUE_URL      = aws_sqs_queue.router.id
    NOTCH_S3_READ_BLOCK_SIZE = 64 * 1024 * 1024
    NOTCH_S3_READ_MAX_BLOCKS = 2
    NOTCH_S3_READ_DEBUG      = false # only turn on when needed, there's a ~10% performance hit
    NOTCH_DEBUG              = terraform.workspace != "production"
  }

  # TODO: use resources/data instead of hardcoding these ARNs.
  registrar_bucket_arn        = terraform.workspace == "production" ? "arn:aws:s3:::mdv-registrar-productionv2-us-east-1" : "arn:aws:s3:::mdv-registrar-${terraform.workspace}-${var.region}"
  registrar_apollo_bucket_arn = terraform.workspace == "production" ? "arn:aws:s3:::mdv-registrar-apollo-productionv2-us-east-1" : "arn:aws:s3:::mdv-registrar-apollo-${terraform.workspace}-${var.region}"
  registered_sns_topic_arn    = terraform.workspace == "production" ? "arn:aws:sns:us-east-1:333957572119:registrar-registered-production-us-east-1" : aws_sns_topic.dummy[0].arn
  notch_bulk_sns_topic_arn    = terraform.workspace == "production" ? "arn:aws:sns:us-east-1:333957572119:notch-bulk-production-us-east-1" : ""

  databricks_job_id = lookup({
    "333957572119" = 485746399329403,
    "526623061664" = 11520694429497,
  }, data.aws_caller_identity.self.account_id, [])

  databricks_monitoring_job_id = lookup({
    "333957572119" = 694646129260807,
    "526623061664" = 11520694429497,
  }, data.aws_caller_identity.self.account_id, [])

  partners = lookup({
    "333957572119" = [
      "Quest Diagnostics",
      "Biocept",
      "Bioreference",
      "Sonic",
      "PAML",
      "Aurora",
      "Xifin",
      "Ovation",
      "Exagen",
      "GTC",
      "Invitae",
      "GeneDx",
      "Guardant",
      "Ellkay",
      "CompanyM",
      "Neogenomics",
      "Foundation",
      "Caris"
    ],
    "526623061664" = ["foo", "bar", "baz", "PathGroup"],
  }, data.aws_caller_identity.self.account_id, [])

  datanator_ids = lookup({
    "333957572119" = [
      1718374218,
      1718374284,
      1721410267,
      1701143124,
      1701143194,
      1718374229,
      1718374230,
      1750184911,
      1751305442,
      1754514046,
      1766585976,
      1766585661,
      1780730413,
    ],
    "526623061664" = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 42, 1766585768],
  }, data.aws_caller_identity.self.account_id, [])

  # This controls the lambdas that are created.
  # Each key becomes a lambda named `notch2-<key>[-<workspace_unless_production_or_integration>]`.
  lambdas = {
    router = {
      policies = {
        cloudwatch  = ["*"],
        ssm_r       = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.self.account_id}:parameter/NOTCH*"],
        sqs_w       = [aws_sqs_queue.router.arn],
        vpc_attach  = ["arn:aws:lambda:${var.region}:${data.aws_caller_identity.self.account_id}:function:*"],
        ecs_run     = [module.ecs.task_definition_arn],
        rds_auth    = ["${local.wazowski.resource_id}/${local.wazowski.user}"],
        assume_role = [local.rds_access_role_arn],
        s3_head = [
          local.registrar_bucket_arn,
          local.registrar_apollo_bucket_arn,
          module.bucket["notch"].arn,
          module.bucket["notch-restricted"].arn,
          module.bucket["notch-apollo"].arn,
          "arn:aws:s3:::mdv-megatron",
          "arn:aws:s3:::mdv-client-delight",
          "arn:aws:s3:::mdv-cyclops"
        ],
        s3_w      = ["${module.bucket["notch-restricted"].arn}/*"],
        dynamo_rw = [module.dynamo["notch-backup${local.env_suffix}"].arn],
      },
      env = {
        NOTCH_WORKSPACE                          = terraform.workspace,
        NOTCH_AWS_MAX_RETRIES                    = local.aws_max_retries,
        NOTCH_METRICS_NAMESPACE                  = local.metrics_namespace,
        NOTCH_SQS_QUEUE_URL                      = aws_sqs_queue.router.id,
        NOTCH_SQS_MESSAGE_LIMIT                  = local.sqs_message_limit,
        NOTCH_SQS_MAX_RECEIVE_COUNT              = local.sqs_max_receive_count,
        NOTCH_ENABLED_PARTNERS                   = join(",", local.partners),
        NOTCH_ENABLED_DATANATOR_IDS              = join(",", local.datanator_ids),
        NOTCH_PREPROCESSOR_ECS_CLUSTER           = module.ecs.cluster_name,
        NOTCH_PREPROCESSOR_ECS_TASK_DEFINITION   = module.ecs.task_definition_arn,
        NOTCH_PREPROCESSOR_ECS_SUBNETS           = join(",", [aws_subnet.pub1.id, aws_subnet.pub2.id]),
        NOTCH_PREPROCESSOR_ECS_SECURITY_GROUP    = aws_security_group.main.id,
        NOTCH_PREPROCESSOR_ECS_IMAGE             = local.preprocessor_image,
        NOTCH_PREPROCESSOR_ECS_CONTAINER_NAME    = local.base_name,
        NOTCH_STAGE_DATABRICKS_JOB_ID            = local.databricks_job_id,
        NOTCH_STAGE_MONITORING_DATABRICKS_JOB_ID = local.databricks_monitoring_job_id,
        NOTCH_NOTCH_BUCKET                       = module.bucket["notch"].name,
        NOTCH_RESTRICTED_BUCKET                  = module.bucket["notch-restricted"].name,
        NOTCH_BACKUP_TABLE                       = module.dynamo["notch-backup${local.env_suffix}"].name,
        NOTCH_WAZOWSKI_HOST                      = local.wazowski.host,
        NOTCH_WAZOWSKI_USER                      = local.wazowski.user,
        NOTCH_WAZOWSKI_DATABASE                  = local.wazowski.database,
        NOTCH_WAZOWSKI_DIAL_TIMEOUT              = local.wazowski.dial_timeout,
        NOTCH_WAZOWSKI_READ_TIMEOUT              = local.wazowski.read_timeout,
        NOTCH_WAZOWSKI_WRITE_TIMEOUT             = local.wazowski.write_timeout,
        NOTCH_WAZOWSKI_CONN_MAX_IDLE_TIME        = local.wazowski.conn_max_idle_time,
        NOTCH_RDS_ROLE_ARN                       = terraform.workspace == "production" ? "" : local.rds_access_role_arn,
        NOTCH_RDS_ROLE_EXTERNAL_ID               = local.rds_access_external_id,
      },
    },
  }

  # This defines the DBs used. The keys become the table names:
  #     platform-<key>
  #
  # NOTE: Only set hash_key if different from "uuid" and range_key if different from "key"
  # (as these are the defaults, if they are null (but NOT if they are set to "", in which
  # case they are not set at all)).
  #
  # NOTE: For so-called "singleton" tables (tables that only have a unique
  # instance, for all envs, typically in production) set singleton = true.
  tables = {
    ("notch-backup${local.env_suffix}") = {
      hash_key  = "id"
      range_key = ""
      attribute_types = {
        datanator_id = "N"
      }
      gsis = [
        {
          name            = "datanator-index"
          hash_key        = "datanator_id"
          range_key       = "timestamp"
          projection_type = "KEYS_ONLY"
        },
        {
          name            = "filename-index"
          hash_key        = "filename"
          projection_type = "KEYS_ONLY"
        },
        {
          name            = "date-index"
          hash_key        = "date" # YYYY-MM-DD format
          range_key       = "timestamp"
          projection_type = "KEYS_ONLY"
        }
      ]
    }
  }

  # S3 bucket definitions for use with the s3_bucket module.
  #
  # Each key is the bucket name (must be valid for S3: lowercase, numbers, hyphens, no underscores).
  #
  # Each value is a map of bucket options. The only required field is `lifecycle_rules`,
  # which itself is a map from rule id to rule options. The rule id becomes the AWS rule id.
  #
  # For lifecycle_rules:
  #   - Only specify fields that differ from the default (status defaults to "Enabled",
  #     filter defaults to all objects).
  #   - To match all objects, omit `filter`.
  #   - To match a prefix, set `filter = { prefix = "your/prefix/" }`.
  #   - See the s3_bucket module variables for all available options.
  #
  # Example:
  # buckets = {
  #   "my-bucket" = {
  #     lifecycle_rules = {
  #       clean = {
  #         expiration = { expired_object_delete_marker = true }
  #         abort_incomplete_multipart_upload = { days_after_initiation = 1 }
  #       }
  #     }
  #   }
  # }
  buckets = {
    notch = {
      lifecycle_rules = {
        tmp = {
          filter     = { prefix = "tmp/" }
          expiration = { days = 30 }
        }
        it = {
          transition = { days = 1, storage_class = "INTELLIGENT_TIERING" }
        }
        clean = {
          expiration                        = { expired_object_delete_marker = true }
          abort_incomplete_multipart_upload = { days_after_initiation = 1 }
        }
      }
    }
    "notch-apollo" = {
      lifecycle_rules = {
        tmp = {
          filter     = { prefix = "tmp/" }
          expiration = { days = 30 }
        }
        it = {
          transition = { days = 1, storage_class = "INTELLIGENT_TIERING" }
        }
        clean = {
          expiration                        = { expired_object_delete_marker = true }
          abort_incomplete_multipart_upload = { days_after_initiation = 1 }
        }
      }
    }
    "notch-restricted" = {
      lifecycle_rules = {
        wipe = {
          filter     = { prefix = "intermediary/" }
          expiration = { days = 1 }
        }
        preprocessor-payloads = {
          filter     = { prefix = "ecs_overrides/" }
          expiration = { days = 14 }
        }
        stage-payloads = {
          filter     = { prefix = "stage_payloads/" }
          expiration = { days = 14 }
        }
        clean = {
          expiration                        = { expired_object_delete_marker = true }
          abort_incomplete_multipart_upload = { days_after_initiation = 1 }
        }
      }
    }
  }

  buckets_normalized = {
    for bucket_name, bucket in local.buckets :
    bucket_name => merge(
      bucket,
      {
        lifecycle_rules = [
          for rule_id, rule in try(bucket.lifecycle_rules, {}) : {
            id                                     = rule_id
            status                                 = try(rule.status, "Enabled")
            prefix                                 = try(rule.filter.prefix, "")
            expiration_days                        = try(rule.expiration.days, null)
            expired_object_delete_marker           = try(rule.expiration.expired_object_delete_marker, null)
            abort_incomplete_multipart_upload_days = try(rule.abort_incomplete_multipart_upload.days_after_initiation, null)
            transition_days                        = try(rule.transition.days, null)
            storage_class                          = try(rule.transition.storage_class, null)
          }
        ]
      }
    )
  }
}
