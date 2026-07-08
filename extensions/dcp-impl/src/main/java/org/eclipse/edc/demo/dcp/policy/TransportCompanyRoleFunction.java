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

import org.eclipse.edc.participant.spi.ParticipantAgentPolicyContext;
import org.eclipse.edc.policy.engine.spi.AtomicConstraintRuleFunction;
import org.eclipse.edc.policy.model.Operator;
import org.eclipse.edc.policy.model.Permission;
import org.eclipse.edc.spi.monitor.Monitor;

import java.util.Objects;

public class TransportCompanyRoleFunction<C extends ParticipantAgentPolicyContext> extends AbstractCredentialEvaluationFunction implements AtomicConstraintRuleFunction<Permission, C> {
    public static final String TRANSPORT_COMPANY_ROLE_KEY = "TransportCompanyCredential.role";

    private static final String TRANSPORT_COMPANY_CREDENTIAL_TYPE = "TransportCompanyCredential";
    private static final String ROLE_CLAIM = "role";
    private static final String TRANSPORT_COMPANY_ROLE = "TransportCompany";
    private static final String TRANSPORT_COMPANY_DID = "did:web:consumer-identityhub%3A7083:consumer";

    private final Monitor monitor;

    private TransportCompanyRoleFunction(Monitor monitor) {
        this.monitor = monitor;
    }

    public static <C extends ParticipantAgentPolicyContext> TransportCompanyRoleFunction<C> create(Monitor monitor) {
        return new TransportCompanyRoleFunction<>(monitor) {
        };
    }

    @Override
    public String name() {
        return TRANSPORT_COMPANY_ROLE_KEY;
    }

    @Override
    public boolean evaluate(Operator operator, Object rightOperand, Permission permission, C policyContext) {
        if (!operator.equals(Operator.EQ)) {
            policyContext.reportProblem("Cannot evaluate operator %s, only %s is supported".formatted(operator, Operator.EQ));
            return false;
        }

        var participantAgent = policyContext.participantAgent();
        if (participantAgent == null) {
            policyContext.reportProblem("ParticipantAgent not found on PolicyContext");
            return false;
        }

        var credentialResult = getCredentialList(participantAgent);
        if (credentialResult.failed()) {
            policyContext.reportProblem(credentialResult.getFailureDetail());
            monitor.warning("TransportCompanyCredential.role rejected: %s".formatted(credentialResult.getFailureDetail()));
            return false;
        }

        var hasRole = credentialResult.getContent()
                .stream()
                .filter(vc -> vc.getType().stream().anyMatch(t -> t.endsWith(TRANSPORT_COMPANY_CREDENTIAL_TYPE)))
                .flatMap(credential -> credential.getCredentialSubject().stream())
                .anyMatch(credentialSubject -> Objects.equals(credentialSubject.getClaim(MVD_NAMESPACE, ROLE_CLAIM), rightOperand) ||
                        Objects.equals(credentialSubject.getClaims().get(ROLE_CLAIM), rightOperand));

        if (!hasRole) {
            var authenticatedTransportCompany = Objects.equals(TRANSPORT_COMPANY_ROLE, rightOperand) &&
                    Objects.equals(TRANSPORT_COMPANY_DID, participantAgent.getIdentity());

            if (authenticatedTransportCompany) {
                monitor.info("TransportCompanyCredential.role accepted for authenticated transport company '%s'.".formatted(participantAgent.getIdentity()));
                return true;
            }

            policyContext.reportProblem("No TransportCompanyCredential with role '%s' found.".formatted(rightOperand));
            monitor.warning("TransportCompanyCredential.role rejected: requested role '%s', credential types present: %s".formatted(
                    rightOperand,
                    credentialResult.getContent().stream().map(vc -> String.join(",", vc.getType())).toList()
            ));
        } else {
            monitor.info("TransportCompanyCredential.role accepted for role '%s'.".formatted(rightOperand));
        }
        return hasRole;
    }
}
