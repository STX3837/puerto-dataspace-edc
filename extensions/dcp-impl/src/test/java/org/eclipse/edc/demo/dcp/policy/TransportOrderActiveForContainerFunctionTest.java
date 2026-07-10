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
import org.eclipse.edc.connector.controlplane.catalog.spi.policy.CatalogPolicyContext;
import org.eclipse.edc.connector.controlplane.contract.spi.policy.ContractNegotiationPolicyContext;
import org.eclipse.edc.participant.spi.ParticipantAgent;
import org.eclipse.edc.policy.engine.spi.PolicyContext;
import org.eclipse.edc.policy.model.Operator;
import org.eclipse.edc.policy.model.Permission;
import org.eclipse.edc.spi.monitor.Monitor;
import org.eclipse.edc.spi.query.QuerySpec;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.eclipse.edc.demo.dcp.policy.TransportOrderActiveForContainerFunction.TRANSPORT_ORDER_ACTIVE_FOR_CONTAINER_KEY;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class TransportOrderActiveForContainerFunctionTest {
    private static final String CONTAINER_PLACEHOLDER = "${containerId}";

    private final AssetIndex assetIndex = mock();
    private final Monitor monitor = mock();
    private final TransportOrderActiveForContainerFunction<PolicyContext> function =
            TransportOrderActiveForContainerFunction.create(assetIndex, monitor);

    @Test
    void shouldDeferPlaceholderEvaluationInCatalogWhenMultipleAssetsExist() {
        when(assetIndex.queryAssets(any(QuerySpec.class))).thenReturn(Stream.of(
                asset("asset-one", "MSCU1111111"),
                asset("asset-two", "MSCU2222222")
        ));

        var context = new CatalogPolicyContext(participantAgent());

        var result = function.evaluate(
                TRANSPORT_ORDER_ACTIVE_FOR_CONTAINER_KEY,
                Operator.EQ,
                CONTAINER_PLACEHOLDER,
                new Permission(),
                context
        );

        assertThat(result).isTrue();
        assertThat(context.hasProblems()).isFalse();
    }

    @Test
    void shouldDeferPlaceholderEvaluationInContractNegotiationWhenMultipleAssetsExist() {
        when(assetIndex.queryAssets(any(QuerySpec.class))).thenReturn(Stream.of(
                asset("asset-one", "MSCU1111111"),
                asset("asset-two", "MSCU2222222")
        ));

        var context = new ContractNegotiationPolicyContext(participantAgent());

        var result = function.evaluate(
                TRANSPORT_ORDER_ACTIVE_FOR_CONTAINER_KEY,
                Operator.EQ,
                CONTAINER_PLACEHOLDER,
                new Permission(),
                context
        );

        assertThat(result).isTrue();
        assertThat(context.hasProblems()).isFalse();
    }

    @Test
    void shouldRejectPlaceholderEvaluationInGenericContextWhenMultipleAssetsExist() {
        when(assetIndex.queryAssets(any(QuerySpec.class))).thenReturn(Stream.of(
                asset("asset-one", "MSCU1111111"),
                asset("asset-two", "MSCU2222222")
        ));

        var context = mock(org.eclipse.edc.policy.engine.spi.PolicyContext.class);
        when(context.scope()).thenReturn("generic.scope");

        var result = function.evaluate(
                TRANSPORT_ORDER_ACTIVE_FOR_CONTAINER_KEY,
                Operator.EQ,
                CONTAINER_PLACEHOLDER,
                new Permission(),
                context
        );

        assertThat(result).isFalse();
    }

    private Asset asset(String id, String containerId) {
        return Asset.Builder.newInstance()
                .id(id)
                .property("containerId", containerId)
                .build();
    }

    private ParticipantAgent participantAgent() {
        return new ParticipantAgent(
                "did:web:consumer-identityhub%3A7083:consumer",
                Map.of(),
                Map.of()
        );
    }
}
