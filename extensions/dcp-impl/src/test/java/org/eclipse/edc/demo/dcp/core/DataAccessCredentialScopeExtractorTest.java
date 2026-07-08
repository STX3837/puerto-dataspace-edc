/*
 *  Copyright (c) 2026 Contributors to the Eclipse Foundation
 *
 *  This program and the accompanying materials are made available under the
 *  terms of the Apache License, Version 2.0 which is available at
 *  https://www.apache.org/licenses/LICENSE-2.0
 *
 *  SPDX-License-Identifier: Apache-2.0
 */

package org.eclipse.edc.demo.dcp.core;

import org.eclipse.edc.policy.model.Operator;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class DataAccessCredentialScopeExtractorTest {

    private final DataAccessCredentialScopeExtractor extractor = new DataAccessCredentialScopeExtractor();

    @Test
    void shouldExtractDataProcessorCredentialScopeForDataAccessConstraint() {
        var scopes = extractor.extractScopes("DataAccess.level", Operator.EQ, "restricted", null);

        assertThat(scopes)
                .containsExactly("org.eclipse.dspace.dcp.vc.type:DataProcessorCredential:read");
    }

    @Test
    void shouldExtractTransportCompanyCredentialScopeForTransportCompanyConstraint() {
        var scopes = extractor.extractScopes("TransportCompanyCredential.role", Operator.EQ, "TransportCompany", null);

        assertThat(scopes)
                .containsExactly("org.eclipse.dspace.dcp.vc.type:TransportCompanyCredential:read");
    }

    @Test
    void shouldNotExtractScopeForUnrelatedOrNonStringConstraint() {
        assertThat(extractor.extractScopes("MembershipCredential", Operator.EQ, "active", null))
                .isEmpty();
        assertThat(extractor.extractScopes(42, Operator.EQ, "active", null))
                .isEmpty();
    }
}
