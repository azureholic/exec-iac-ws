# syntax=docker/dockerfile:1.7
# Build context is this folder (workload-app/backend/HotelBooking.Api).

# ---------- build stage ----------
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

COPY HotelBooking.Api.csproj ./
RUN dotnet restore HotelBooking.Api.csproj

COPY . .
# Drop any stray local build state that leaked through .dockerignore so
# the publish step uses only the freshly-restored package graph.
RUN rm -rf bin obj
RUN dotnet publish HotelBooking.Api.csproj \
    -c Release \
    -o /app/publish \
    /p:UseAppHost=false

# ---------- runtime stage ----------
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app

# Non-root user (the aspnet image ships an "app" user with uid 1654).
USER app

ENV ASPNETCORE_URLS=http://+:8080 \
    DOTNET_RUNNING_IN_CONTAINER=true \
    DOTNET_NOLOGO=true

COPY --from=build --chown=app:app /app/publish ./

EXPOSE 8080
ENTRYPOINT ["dotnet", "HotelBooking.Api.dll"]
