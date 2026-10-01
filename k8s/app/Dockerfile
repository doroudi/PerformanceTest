# Runtime-only image for a .NET application under load test.
#
# The build context is a folder produced by `dotnet publish` on the HOST, not the
# source tree. That is deliberate, and it is the opposite of the usual multi-stage
# Dockerfile:
#
#   * An application often restores from PRIVATE NuGet feeds whose credentials live
#     in the user-level NuGet.Config. A multi-stage build using the SDK image would
#     need those credentials inside the build, where they are baked into a layer and
#     therefore into the image history and any registry it is pushed to.
#   * Publishing first also means the image contains exactly what runs: no SDK, no
#     NuGet cache, no source, no .git. Roughly 340MB instead of well over 1GB.
#   * It keeps the slow, cache-friendly part (restore + build) on the host, where
#     the NuGet cache and SDK already are, so rebuilding the image after a code
#     change is seconds rather than minutes.
#
# The trade-off, stated honestly: the image is only as reproducible as the machine
# that published it, because the build inputs are not pinned inside the build.
# For a local performance test that is the right trade. For CI, use a multi-stage
# Dockerfile with the NuGet.config supplied as a BuildKit secret
# (`RUN --mount=type=secret,id=nugetconfig ...`), which keeps the token out of
# every layer while still building from the source tree.

ARG DOTNET_IMAGE=mcr.microsoft.com/dotnet/aspnet:10.0
FROM ${DOTNET_IMAGE}

# Which assembly to start. The build script finds the .dll that has a matching
# .runtimeconfig.json in the publish output and passes its name here, so this image
# works for any .NET app instead of hard-coding one assembly name. The exec form of
# ENTRYPOINT cannot expand variables, hence the shell below.
ARG APP_DLL=app.dll
ENV APP_DLL=${APP_DLL}

WORKDIR /app
COPY . /app

# Kestrel must listen on ALL interfaces inside a container. Binding to localhost
# would leave the Service with nothing to route to - the container equivalent of
# pointing a load test at `localhost` and measuring the wrong process.
#
# ASPNETCORE_ENVIRONMENT is Production on purpose: a Development environment
# enables the developer exception page and verbose logging, which changes both
# latency and throughput. The measured configuration is the experiment.
ENV ASPNETCORE_URLS=http://+:8080 \
    ASPNETCORE_ENVIRONMENT=Production \
    DOTNET_RUNNING_IN_CONTAINER=true \
    DOTNET_EnableDiagnostics=1

EXPOSE 8080

# `exec` matters: it makes the runtime PID 1 so it receives SIGTERM directly.
# Without it the shell swallows the signal and every rolling restart or scale-down
# has to wait out the full terminationGracePeriodSeconds.
ENTRYPOINT ["/bin/sh", "-c", "exec dotnet \"$APP_DLL\""]
