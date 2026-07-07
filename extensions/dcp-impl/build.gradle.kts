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
*       Bayerische Motoren Werke Aktiengesellschaft (BMW AG) - Initial API and Implementation
*
*/

plugins {
    `java-library`
}

val edcVersion = "0.14.1"

dependencies {
    compileOnly("org.eclipse.edc:core-spi:$edcVersion")
    compileOnly("org.eclipse.edc:runtime-metamodel:$edcVersion")

    compileOnly("org.eclipse.edc:identity-trust-spi:$edcVersion")
    compileOnly("org.eclipse.edc:verifiable-credential-spi:$edcVersion")

    compileOnly("org.eclipse.edc:policy-engine-spi:$edcVersion")
    compileOnly("org.eclipse.edc:request-policy-context-spi:$edcVersion")
    compileOnly("org.eclipse.edc:policy-model:$edcVersion")

    compileOnly("org.eclipse.edc:transform-spi:$edcVersion")
    compileOnly("org.eclipse.edc:transform-lib:$edcVersion")
    compileOnly("org.eclipse.edc:jws2020-lib:$edcVersion")

    compileOnly("org.eclipse.edc:catalog-spi:$edcVersion")
    compileOnly("org.eclipse.edc:contract-spi:$edcVersion")

    testImplementation("org.eclipse.edc:core-spi:$edcVersion")
    testImplementation("org.eclipse.edc:identity-trust-spi:$edcVersion")
    testImplementation("org.eclipse.edc:participant-spi:$edcVersion")
    testImplementation("org.eclipse.edc:policy-engine-spi:$edcVersion")
    testImplementation("org.eclipse.edc:policy-model:$edcVersion")
    testImplementation("org.eclipse.edc:request-policy-context-spi:$edcVersion")
    testImplementation("org.eclipse.edc:verifiable-credential-spi:$edcVersion")
    testImplementation("org.eclipse.edc:verifiable-credentials-spi:$edcVersion")

    testImplementation("org.junit.jupiter:junit-jupiter-api:5.10.3")
    testRuntimeOnly("org.junit.jupiter:junit-jupiter-engine:5.10.3")
    testImplementation("org.assertj:assertj-core:3.26.3")
    testImplementation("org.mockito:mockito-core:5.12.0")
}

tasks.test {
    useJUnitPlatform()
}
