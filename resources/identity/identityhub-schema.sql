--
--  Copyright (c) 2024 Bayerische Motoren Werke Aktiengesellschaft (BMW AG)
--
--  This program and the accompanying materials are made available under the
--  terms of the Apache License, Version 2.0 which is available at
--  https://www.apache.org/licenses/LICENSE-2.0
--
--  SPDX-License-Identifier: Apache-2.0
--
--  Contributors:
--       Bayerische Motoren Werke Aktiengesellschaft (BMW AG) - initial API and implementation
--
--

CREATE TABLE IF NOT EXISTS edc_lease
(
    leased_by      VARCHAR NOT NULL,
    leased_at      BIGINT,
    lease_duration INTEGER NOT NULL,
    resource_id    VARCHAR NOT NULL,
    resource_kind  VARCHAR NOT NULL,
    PRIMARY KEY(resource_id, resource_kind)
);

CREATE TABLE IF NOT EXISTS participant_context
(
    participant_context_id VARCHAR PRIMARY KEY NOT NULL,
    identity               VARCHAR UNIQUE      NOT NULL,
    created_date           BIGINT              NOT NULL,
    last_modified_date     BIGINT,
    state                  INTEGER             NOT NULL,
    properties             JSON DEFAULT '{}'
);

CREATE UNIQUE INDEX IF NOT EXISTS participant_context_participant_context_id_uindex
    ON participant_context USING btree (participant_context_id);

CREATE TABLE IF NOT EXISTS edc_participant_context_config
(
    participant_context_id VARCHAR PRIMARY KEY NOT NULL,
    created_date           BIGINT              NOT NULL,
    last_modified_date     BIGINT,
    entries                JSON DEFAULT '{}',
    private_entries        JSON DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS keypair_resource
(
    id                     VARCHAR PRIMARY KEY NOT NULL,
    participant_context_id VARCHAR,
    timestamp              BIGINT              NOT NULL,
    key_id                 VARCHAR             NOT NULL,
    group_name             VARCHAR,
    is_default_pair        BOOLEAN DEFAULT FALSE,
    use_duration           BIGINT,
    rotation_duration      BIGINT,
    serialized_public_key  VARCHAR             NOT NULL,
    private_key_alias      VARCHAR             NOT NULL,
    state                  INT     DEFAULT 100 NOT NULL,
    key_context            VARCHAR,
    usage                  VARCHAR             NOT NULL
);

CREATE TABLE IF NOT EXISTS did_resources
(
    did                    VARCHAR NOT NULL,
    create_timestamp       BIGINT  NOT NULL,
    state_timestamp        BIGINT  NOT NULL,
    state                  INT     NOT NULL,
    did_document           JSON    NOT NULL,
    participant_context_id VARCHAR,
    PRIMARY KEY (did)
);

CREATE TABLE IF NOT EXISTS credential_resource
(
    id                     VARCHAR PRIMARY KEY NOT NULL,
    create_timestamp       BIGINT              NOT NULL,
    issuer_id              VARCHAR             NOT NULL,
    holder_id              VARCHAR             NOT NULL,
    vc_state               INTEGER             NOT NULL,
    metadata               JSON DEFAULT '{}',
    issuance_policy        JSON,
    reissuance_policy      JSON,
    raw_vc                 VARCHAR,
    vc_format              INTEGER             NOT NULL,
    verifiable_credential  JSON                NOT NULL,
    participant_context_id VARCHAR,
    usage                  VARCHAR             NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS credential_resource_credential_id_uindex
    ON credential_resource USING btree (id);

CREATE TABLE IF NOT EXISTS edc_holder_credentialrequest
(
    id                     VARCHAR           NOT NULL PRIMARY KEY,
    state                  INTEGER           NOT NULL,
    state_count            INTEGER DEFAULT 0 NOT NULL,
    state_time_stamp       BIGINT,
    created_at             BIGINT            NOT NULL,
    updated_at             BIGINT            NOT NULL,
    trace_context          JSON,
    error_detail           VARCHAR,
    pending                BOOLEAN DEFAULT FALSE,
    participant_context_id VARCHAR           NOT NULL,
    issuer_did             VARCHAR           NOT NULL,
    ids_and_formats        JSON              NOT NULL,
    issuer_pid             VARCHAR
);

CREATE INDEX IF NOT EXISTS issuance_process_state
    ON edc_holder_credentialrequest (state, state_time_stamp);

CREATE TABLE IF NOT EXISTS edc_credential_offers
(
    id                     VARCHAR NOT NULL PRIMARY KEY,
    state                  INTEGER NOT NULL,
    state_count            INTEGER DEFAULT 0 NOT NULL,
    state_time_stamp       BIGINT,
    created_at             BIGINT  NOT NULL,
    updated_at             BIGINT  NOT NULL,
    trace_context          JSON,
    error_detail           VARCHAR,
    participant_context_id VARCHAR NOT NULL,
    issuer_did             VARCHAR NOT NULL,
    credentials            JSON    NOT NULL DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS credential_offer_state
    ON edc_credential_offers (state, state_time_stamp);

CREATE TABLE IF NOT EXISTS edc_sts_client
(
    id                     VARCHAR NOT NULL PRIMARY KEY,
    client_id              VARCHAR NOT NULL,
    did                    VARCHAR NOT NULL,
    name                   VARCHAR NOT NULL,
    secret_alias           VARCHAR NOT NULL,
    created_at             BIGINT  NOT NULL,
    participant_context_id VARCHAR NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS sts_client_client_id_index
    ON edc_sts_client (client_id);

CREATE TABLE IF NOT EXISTS edc_jti_validation
(
    token_id   VARCHAR NOT NULL PRIMARY KEY,
    expires_at BIGINT
);
