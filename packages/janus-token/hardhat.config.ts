import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";

const deployKey =
  process.env.DEPLOY_PRIVATE_KEY ??
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"; // hardhat default

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    hardhat: {},
    "flow-evm-testnet": {
      url: "https://testnet.evm.nodes.onflow.org",
      chainId: 545,
      accounts: [deployKey],
    },
  },
  paths: {
    sources: "./contracts/solidity",
    tests: "./tests/solidity",
    cache: "./cache",
    artifacts: "./artifacts",
  },
};

export default config;
