# Build the WAR with Maven, then deploy it as ROOT.war on standalone Tomcat 10.1.
FROM maven:3-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml .
RUN mvn -q -B dependency:go-offline
COPY src ./src
RUN mvn -q -B package -DskipTests

FROM tomcat:10.1-jdk21
RUN rm -rf /usr/local/tomcat/webapps/*
COPY --from=build /src/target/ROOT.war /usr/local/tomcat/webapps/ROOT.war
