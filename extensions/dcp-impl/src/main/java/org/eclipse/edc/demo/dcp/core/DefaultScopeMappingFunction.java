/*
 *  Copyright (c) 2023 Bayerische Motoren Werke Aktiengesellschaft (BMW AG)
 *
 *  This program and the accompanying materials are made available under the
 *  terms of the Apache License, Version 2.0 which is available at
 *  https://www.apache.org/licenses/LICENSE-2.0
 *
 *  SPDX-License-Identifier: Apache-2.0
 *
 *  Contributors:
 *       Bayerische Motoren Werke Aktiengesellschaft (BMW AG) - initial API and implementation
 *
 */

package org.eclipse.edc.demo.dcp.core;

import org.eclipse.edc.policy.context.request.spi.RequestPolicyContext;
import org.eclipse.edc.policy.engine.spi.PolicyValidatorRule;
import org.eclipse.edc.policy.model.Policy;
import org.eclipse.edc.spi.iam.RequestContext;

import java.util.LinkedHashSet;
import java.util.Set;

public class DefaultScopeMappingFunction implements PolicyValidatorRule<RequestPolicyContext> {
    private final Set<String> egressScopes;
    private final Set<String> ingressScopes;

    public DefaultScopeMappingFunction(Set<String> defaultScopes) {
        this(defaultScopes, defaultScopes);
    }

    public DefaultScopeMappingFunction(Set<String> egressScopes, Set<String> ingressScopes) {
        this.egressScopes = egressScopes;
        this.ingressScopes = ingressScopes;
    }

    @Override
    public Boolean apply(Policy policy, RequestPolicyContext requestPolicyContext) {
        var requestScopeBuilder = requestPolicyContext.requestScopeBuilder();
        var rq = requestScopeBuilder.build();
        var existingScope = rq.getScopes();
        var direction = requestPolicyContext.requestContext().getDirection();
        var defaultScopes = direction == RequestContext.Direction.Egress ? egressScopes : ingressScopes;
        var newScopes = new LinkedHashSet<>(defaultScopes);
        if (shouldIncludePolicyScopes(requestPolicyContext)) {
            newScopes.addAll(existingScope);
        }
        requestScopeBuilder.scopes(newScopes);
        return true;
    }

    private boolean shouldIncludePolicyScopes(RequestPolicyContext requestPolicyContext) {
        var message = requestPolicyContext.requestContext().getMessage();
        if (message == null) {
            return true;
        }

        return switch (message.getClass().getSimpleName()) {
            case "ContractAgreementMessage",
                 "ContractAgreementVerificationMessage",
                 "ContractNegotiationEventMessage",
                 "ContractNegotiationTerminationMessage",
                 "ContractOfferMessage",
                 "TransferStartMessage",
                 "TransferSuspensionMessage",
                 "TransferCompletionMessage",
                 "TransferTerminationMessage" -> false;
            default -> true;
        };
    }
}
