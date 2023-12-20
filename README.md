# ersd-keycloak
> Keycloak for ERSD

Please note this is using [jboss/keycloak from Docker hub](https://hub.docker.com/r/jboss/keycloak/).  Go [there](https://hub.docker.com/r/jboss/keycloak/) for more information if needed.

# Run With MySQL as Database
```bash
docker run -p 8080:8080 -e KEYCLOAK_USER=<KC_MASTER_USERNAME> -e KEYCLOAK_PASSWORD=<KC_MASTER_PASS> -e DB_VENDOR=mysql -e DB_ADDR=<DB_ADDR> -e DB_USER=<DB_USER> -e DB_PASSWORD=<DB_PASS> -t jboss/keycloak
```

# Configuration
Run the configure script provided in this repository. Please note it can be run from anywhere.  It does not need to be run from within the Keycloak container. 
```bash
# Run a Docker image that houses the configure script
docker run -it registry.ruvos.com/ersd/ersd-keycloak

# Or clone and execute
git clone git@gitlab.ruvos.com:ersd/ersd-keycloak.git
./ersd-keycloak/configure
```

Either way, provide `configure` with keycloak credentials and the desired setup options, and it should perform the following:
- Authenticates against the keycloak service located at the base URL you provide
- Creates a realm of your choosing, which defaults to `ersd`
- Creates the `admin` realm role on the newly created realm
- Creates a client of your choosing, which defaults to `ersd-app`
- Fetches the authentication certificate for the newly created realm and writes it to standard out

All of these are requirements of the [ERSD Node application](https://gitlab.ruvos.com/ersd/ersd) and should be reflected in the configuration there as well.

#Manual Deployment 
```bash
# Build the docker image and tag it for upload
./build

# Retrieve an authentication token and authenticate your Docker client to your registry. Use the AWS CLI:
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 703861148810.dkr.ecr.us-east-1.amazonaws.com
# Run the following command to push this image to your newly created AWS repository:
docker push 703861148810.dkr.ecr.us-east-1.amazonaws.com/ersd/ersd-keycloak:latest
```