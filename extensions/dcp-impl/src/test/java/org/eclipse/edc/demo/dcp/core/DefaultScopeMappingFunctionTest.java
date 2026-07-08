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

import org.eclipse.edc.policy.context.request.spi.RequestPolicyContext;
import org.eclipse.edc.spi.iam.RequestContext;
import org.eclipse.edc.spi.iam.RequestScope;
import org.junit.jupiter.api.Test;

import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class DefaultScopeMappingFunctionTest {

    @Test
    void shouldMergeDefaultAndExistingScopesWithoutDuplicates() {
        var requestScopeBuilder = RequestScope.Builder.newInstance()
                .scopes(Set.of("existing:read", "membership:read"));
        var requestContext = RequestContext.Builder.newInstance()
                .direction(RequestContext.Direction.Egress)
                .build();
        var context = mock(RequestPolicyContext.class);
        when(context.requestScopeBuilder()).thenReturn(requestScopeBuilder);
        when(context.requestContext()).thenReturn(requestContext);

        var function = new DefaultScopeMappingFunction(Set.of("membership:read", "default:read"));

        assertThat(function.apply(null, context)).isTrue();
        assertThat(requestScopeBuilder.build().getScopes())
                .containsExactlyInAnyOrder("existing:read", "membership:read", "default:read");
    }
}
