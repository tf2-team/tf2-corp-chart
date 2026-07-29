@{
    schemaVersion = 1
    accountId = "493499579600"
    region = "us-east-1"
    clusterContext = "arn:aws:eks:us-east-1:493499579600:cluster/techx-tf2-prod"
    chartGitSha = "<40-lowercase-hex>"
    infraGitSha = "<40-lowercase-hex>"
    contractSha256 = "<64-lowercase-hex>"
    templates = @(
        @{ variant = "1a-primary-in"; templateId = "EXT2UboGoZ7ErXaQ"; revisionSha256 = "<64-lowercase-hex>"; lastUpdateTime = "<AWS timestamp>" }
        @{ variant = "1a-primary-outside"; templateId = "EXT2cGQZ1Hb4HKCC"; revisionSha256 = "<64-lowercase-hex>"; lastUpdateTime = "<AWS timestamp>" }
        @{ variant = "1b-primary-in"; templateId = "EXTDqvVeTfQiN7zBS"; revisionSha256 = "<64-lowercase-hex>"; lastUpdateTime = "<AWS timestamp>" }
        @{ variant = "1b-primary-outside"; templateId = "EXT34dobGM9bVqZ2"; revisionSha256 = "<64-lowercase-hex>"; lastUpdateTime = "<AWS timestamp>" }
    )
    evidence = @{ infraPreflightSha256 = "<sha256>"; capacity1aTo1bSha256 = "<sha256>"; capacity1bTo1aSha256 = "<sha256>"; auditAlarmSha256 = "<sha256>" }
    CapacityApproved = "PASS"
    ChangeApproved = "PASS"
    approvedBy = "<approver>"
    changeReference = "<change-ticket>"
    approvedAt = "<UTC timestamp>"
    expiresAt = "<UTC timestamp no more than 24h later>"
}

# Change trail: @hungxqt - 2026-07-29 - Added a two-gate revision-bound FIS approval example without CostApproved.