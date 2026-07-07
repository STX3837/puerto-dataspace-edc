/*
 *  Copyright (c) 2026
 *
 *  This program and the accompanying materials are made available under the
 *  terms of the Apache License, Version 2.0 which is available at
 *  https://www.apache.org/licenses/LICENSE-2.0
 *
 *  SPDX-License-Identifier: Apache-2.0
 */

package org.eclipse.edc.demo.dcp.policy;

import org.eclipse.edc.connector.controlplane.asset.spi.domain.Asset;
import org.eclipse.edc.connector.controlplane.asset.spi.index.AssetIndex;
import org.eclipse.edc.connector.controlplane.contract.spi.policy.TransferProcessPolicyContext;
import org.eclipse.edc.participant.spi.ParticipantAgentPolicyContext;
import org.eclipse.edc.policy.engine.spi.AtomicConstraintRuleFunction;
import org.eclipse.edc.policy.model.Operator;
import org.eclipse.edc.policy.model.Permission;
import org.eclipse.edc.spi.query.QuerySpec;

import java.io.IOException;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Objects;

public class TransportOrderActiveForContainerFunction<C extends ParticipantAgentPolicyContext> implements AtomicConstraintRuleFunction<Permission, C> {
    public static final String TRANSPORT_ORDER_ACTIVE_FOR_CONTAINER_KEY = "TransportOrder.activeForContainer";

    private static final String CONTAINER_ID_PROPERTY = "containerId";
    private static final String CONTAINER_ID_PLACEHOLDER = "${containerId}";
    private static final String VALID_ORDER_RESPONSE_FIELD = "\"transportOrderValid\":true";
    private static final String VALIDATION_ENDPOINT_TEMPLATE = "http://regulatory-clearance-api:8081/transport-orders/TC-A/%s/validate";

    private final AssetIndex assetIndex;
    private final HttpClient httpClient;

    private TransportOrderActiveForContainerFunction(AssetIndex assetIndex, HttpClient httpClient) {
        this.assetIndex = assetIndex;
        this.httpClient = httpClient;
    }

    public static <C extends ParticipantAgentPolicyContext> TransportOrderActiveForContainerFunction<C> create(AssetIndex assetIndex) {
        return new TransportOrderActiveForContainerFunction<>(assetIndex, HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(3))
                .build());
    }

    @Override
    public boolean evaluate(Operator operator, Object rightOperand, Permission permission, C policyContext) {
        if (!operator.equals(Operator.EQ)) {
            policyContext.reportProblem("Cannot evaluate operator %s, only %s is supported".formatted(operator, Operator.EQ));
            return false;
        }

        var containerId = resolveContainerId(rightOperand, policyContext);
        if (containerId == null || containerId.isBlank()) {
            policyContext.reportProblem("Could not resolve containerId from asset properties.");
            return false;
        }

        return validateTransportOrder(containerId, policyContext);
    }

    private String resolveContainerId(Object rightOperand, C policyContext) {
        if (!Objects.equals(CONTAINER_ID_PLACEHOLDER, rightOperand)) {
            return Objects.toString(rightOperand, null);
        }

        var asset = resolveAsset(policyContext);
        if (asset == null) {
            return null;
        }

        return Objects.toString(asset.getProperty(CONTAINER_ID_PROPERTY), null);
    }

    private Asset resolveAsset(C policyContext) {
        if (policyContext instanceof TransferProcessPolicyContext transferContext) {
            return assetIndex.findById(transferContext.contractAgreement().getAssetId());
        }

        try (var assets = assetIndex.queryAssets(QuerySpec.max())) {
            var matchingAssets = assets
                    .filter(asset -> asset.getProperty(CONTAINER_ID_PROPERTY) != null)
                    .toList();

            if (matchingAssets.size() == 1) {
                return matchingAssets.get(0);
            }

            policyContext.reportProblem("Expected exactly one asset with property '%s', found %d.".formatted(CONTAINER_ID_PROPERTY, matchingAssets.size()));
            return null;
        }
    }

    private boolean validateTransportOrder(String containerId, C policyContext) {
        var encodedContainerId = URLEncoder.encode(containerId, StandardCharsets.UTF_8);
        var request = HttpRequest.newBuilder(URI.create(VALIDATION_ENDPOINT_TEMPLATE.formatted(encodedContainerId)))
                .timeout(Duration.ofSeconds(5))
                .GET()
                .build();

        try {
            var response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
            if (response.statusCode() < 200 || response.statusCode() >= 300) {
                policyContext.reportProblem("Transport order validation failed with status %d for container '%s'.".formatted(response.statusCode(), containerId));
                return false;
            }

            var valid = response.body().replace(" ", "").contains(VALID_ORDER_RESPONSE_FIELD);
            if (!valid) {
                policyContext.reportProblem("No active transport order found for container '%s'.".formatted(containerId));
            }
            return valid;
        } catch (IOException exception) {
            policyContext.reportProblem("Transport order validation failed for container '%s': %s".formatted(containerId, exception.getMessage()));
            return false;
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            policyContext.reportProblem("Transport order validation interrupted for container '%s'.".formatted(containerId));
            return false;
        }
    }
}
