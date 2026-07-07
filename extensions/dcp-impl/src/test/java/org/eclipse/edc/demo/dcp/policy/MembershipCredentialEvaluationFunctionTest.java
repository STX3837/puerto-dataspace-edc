/*
 *  Copyright (c) 2026 Contributors to the Eclipse Foundation
 *
 *  This program and the accompanying materials are made available under the
 *  terms of the Apache License, Version 2.0 which is available at
 *  https://www.apache.org/licenses/LICENSE-2.0
 *
 *  SPDX-License-Identifier: Apache-2.0
 */

package org.eclipse.edc.demo.dcp.policy;

import org.eclipse.edc.iam.verifiablecredentials.spi.model.CredentialSubject;
import org.eclipse.edc.iam.verifiablecredentials.spi.model.VerifiableCredential;
import org.eclipse.edc.participant.spi.ParticipantAgent;
import org.eclipse.edc.participant.spi.ParticipantAgentPolicyContext;
import org.eclipse.edc.policy.model.Operator;
import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class MembershipCredentialEvaluationFunctionTest {

    private final MembershipCredentialEvaluationFunction<ParticipantAgentPolicyContext> function =
            MembershipCredentialEvaluationFunction.create();

    @Test
    void shouldAcceptActiveMembershipCredentialIssuedInThePast() {
        var context = contextWithCredential(membershipCredential(Map.of(
                "since", Instant.now().minusSeconds(60).toString()
        )));

        assertThat(function.evaluate(Operator.EQ, "active", null, context)).isTrue();
    }

    @Test
    void shouldRejectMembershipThatStartsInTheFuture() {
        var context = contextWithCredential(membershipCredential(Map.of(
                "since", Instant.now().plusSeconds(3600).toString()
        )));

        assertThat(function.evaluate(Operator.EQ, "active", null, context)).isFalse();
    }

    @Test
    void shouldRejectMalformedMembershipClaimWithoutThrowing() {
        var malformedDate = contextWithCredential(membershipCredential(Map.of("since", "not-an-instant")));
        var malformedObject = contextWithCredential(membershipCredential("not-an-object"));

        assertThat(function.evaluate(Operator.EQ, "active", null, malformedDate)).isFalse();
        assertThat(function.evaluate(Operator.EQ, "active", null, malformedObject)).isFalse();
    }

    @Test
    void shouldRejectUnsupportedOperatorAndRightOperand() {
        var context = contextWithCredential(membershipCredential(Map.of(
                "since", Instant.now().minusSeconds(60).toString()
        )));

        assertThat(function.evaluate(Operator.NEQ, "active", null, context)).isFalse();
        verify(context).reportProblem(contains("Invalid operator"));

        var secondContext = contextWithCredential(membershipCredential(Map.of(
                "since", Instant.now().minusSeconds(60).toString()
        )));
        assertThat(function.evaluate(Operator.EQ, "inactive", null, secondContext)).isFalse();
        verify(secondContext).reportProblem(contains("Right-operand"));
    }

    @Test
    void shouldRejectRequestWithoutParticipantAgent() {
        var context = mock(ParticipantAgentPolicyContext.class);

        assertThat(function.evaluate(Operator.EQ, "active", null, context)).isFalse();
        verify(context).reportProblem(contains("No ParticipantAgent"));
    }

    @Test
    void shouldRejectParticipantWithoutCredentials() {
        var context = mock(ParticipantAgentPolicyContext.class);
        when(context.participantAgent()).thenReturn(new ParticipantAgent(Map.of(), Map.of()));

        assertThat(function.evaluate(Operator.EQ, "active", null, context)).isFalse();
        verify(context).reportProblem(contains("did not contain a 'vc' claim"));
    }

    private ParticipantAgentPolicyContext contextWithCredential(VerifiableCredential credential) {
        var context = mock(ParticipantAgentPolicyContext.class);
        var agent = new ParticipantAgent(Map.of("vc", List.of(credential)), Map.of());
        when(context.participantAgent()).thenReturn(agent);
        return context;
    }

    private VerifiableCredential membershipCredential(Object membershipClaim) {
        var subject = new CredentialSubject();
        subject.setClaim("membership", membershipClaim);

        var credential = mock(VerifiableCredential.class);
        when(credential.getType()).thenReturn(List.of("MembershipCredential"));
        when(credential.getCredentialSubject()).thenReturn(List.of(subject));
        return credential;
    }
}
