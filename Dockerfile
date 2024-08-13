# syntax=docker.io/docker/dockerfile:1

# build stage: includes resources necessary for installing dependencies

# Here the image's platform does not necessarily have to be riscv64.
# If any needed dependencies rely on native binaries, you must use 
# a riscv64 image such as cartesi/node:20-jammy for the build stage,
# to ensure that the appropriate binaries will be generated.
FROM node:20.8.0-bookworm as build-stage

WORKDIR /opt/cartesi/dapp
COPY . .
RUN yarn install && yarn build

# runtime stage: produces final image that will be executed

# Here the image's platform MUST be linux/riscv64.
# Give preference to small base images, which lead to better start-up
# performance when loading the Cartesi Machine.
FROM --platform=linux/riscv64 cartesi/node:20.8.0-jammy-slim

ARG MACHINE_EMULATOR_TOOLS_VERSION=0.14.1
ADD https://github.com/cartesi/machine-emulator-tools/releases/download/v${MACHINE_EMULATOR_TOOLS_VERSION}/machine-emulator-tools-v${MACHINE_EMULATOR_TOOLS_VERSION}.deb /
RUN dpkg -i /machine-emulator-tools-v${MACHINE_EMULATOR_TOOLS_VERSION}.deb \
  && rm /machine-emulator-tools-v${MACHINE_EMULATOR_TOOLS_VERSION}.deb

LABEL io.cartesi.rollups.sdk_version=0.6.0
LABEL io.cartesi.rollups.ram_size=128Mi

ARG DEBIAN_FRONTEND=noninteractive
RUN <<EOF
set -e
apt-get update
apt-get install -y --no-install-recommends \
  busybox-static=1:1.30.1-7ubuntu3
rm -rf /var/lib/apt/lists/* /var/log/* /var/cache/*
useradd --create-home --user-group dapp
EOF
RUN npm i -g snarkjs
ENV PATH="/opt/cartesi/bin:${PATH}"

WORKDIR /opt/cartesi/dapp
COPY --from=build-stage /opt/cartesi/dapp/dist .
COPY --from=build-stage /opt/cartesi/dapp/1_js .
ENV ROLLUP_HTTP_SERVER_URL="http://127.0.0.1:5004"

ENTRYPOINT ["rollup-init"]
#CMD ["node","generate_witness.js","1.wasm","input.json","witness.wtns"]
RUN node generate_witness.js 1.wasm input.json witness.wtns
RUN snarkjs powersoftau new bn128 12 pot12_0000.ptau -v
RUN snarkjs powersoftau contribute pot12_0000.ptau pot12_0001.ptau --name="First contribution" -v -e="first random text"
RUN snarkjs powersoftau prepare phase2 pot12_0001.ptau pot12_final.ptau -v -e="second random text"
RUN snarkjs groth16 setup 1.r1cs pot12_final.ptau multiplier2_0000.zkey 
RUN snarkjs zkey contribute multiplier2_0000.zkey multiplier2_0001.zkey --name="1st Contributor Name" -v -e="random key"
RUN snarkjs zkey export verificationkey multiplier2_0001.zkey verification_key.json
RUN snarkjs groth16 prove multiplier2_0001.zkey witness.wtns proof.json public.json
RUN snarkjs groth16 verify verification_key.json public.json proof.json
RUN snarkjs zkey export solidityverifier multiplier2_0001.zkey verifier.sol
RUN snarkjs generatecall
CMD ["node", "index.js"]


