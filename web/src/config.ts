/**
 * The site's single configuration file: chain, addresses, public RPCs, ABIs and the wagmi config.
 * Addresses come from .imd/reads/deployment.json and .imd/reads/network.json (Ethereum mainnet).
 */
import { createConfig, fallback, http } from "wagmi";
import { mainnet } from "wagmi/chains";
import { coinbaseWallet, injected, walletConnect } from "wagmi/connectors";
import type { Address } from "viem";

export const SITE_NAME = "SwarmPeg";
export const SITE_DESCRIPTION =
  "A fixed-supply Ethereum token whose whole units each own a unique animated on-chain glyph.";
export const SITE_URL = "https://github.com/identity-md-launches/launch-1941-swarmpeg";
export const SITE_ICON_URL = `${SITE_URL}/raw/main/web/public/favicon.svg`;

export const CHAIN_ID = 1;
export const EXPLORER = "https://etherscan.io";

/** Deployed contracts (deployment.json, sourceCommit 37f3cb86444d8acde5b6914cf8597eb365f289d7). */
export const ADDRESSES = {
  token: "0x04d3acf2ddfa87418ba1b2ab99a1301f33135065" as Address,
  hook: "0x1550a30c40f33ff64b68b7ec2ba552eca47ca0cc" as Address,
  imd: "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7" as Address,
  poolManager: "0x000000000004444c5dc75cb358380d2e3de08a90" as Address,
  universalRouter: "0x66a9893cc07d91d95644aedd05d03f95e1dba8af" as Address,
  quoter: "0x52f0e24d1c21c8a0cb1e5a5dd6198556bd9e1203" as Address,
  stateView: "0x7ffe42c4a5deea5b0fec41c94c136cf115597227" as Address,
  permit2: "0x000000000022d473030f116ddee9f6b43ac78ba3" as Address,
} as const;

/** Block the token and hook were created in (deployment.json). Event scans start here. */
export const DEPLOY_BLOCK = 26203846n;

export const POOL = { lpFee: 12500, tickSpacing: 60 } as const;

export const LINKS = {
  token: `${EXPLORER}/address/${ADDRESSES.token}`,
  hook: `${EXPLORER}/address/${ADDRESSES.hook}`,
  imd: `${EXPLORER}/address/${ADDRESSES.imd}`,
  uniswap: `https://app.uniswap.org/explore/tokens/ethereum/${ADDRESSES.token}`,
  repo: "https://github.com/identity-md-launches/launch-1941-swarmpeg",
} as const;

export const RPC_URLS = ["https://ethereum-rpc.publicnode.com", "https://eth.drpc.org"] as const;

/** wallet_addEthereumChain parameters from network.json, used when a wallet does not know the chain. */
export const WALLET_ADD_CHAIN = {
  chainId: "0x1",
  chainName: "Ethereum",
  rpcUrls: [...RPC_URLS],
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  blockExplorerUrls: [EXPLORER],
} as const;

export const chain = {
  ...mainnet,
  rpcUrls: { default: { http: [...RPC_URLS] } },
} as const;

/** Only when the brief supplies one. None was supplied, so the WalletConnect row is not wired. */
export const walletConnectProjectId = "";

export const config = createConfig({
  chains: [chain],
  // EIP-6963 discovery lists every installed extension under its own name.
  multiInjectedProviderDiscovery: true,
  connectors: [
    injected(),
    ...(walletConnectProjectId
      ? [
          walletConnect({
            projectId: walletConnectProjectId,
            showQrModal: true,
            metadata: { name: SITE_NAME, description: SITE_DESCRIPTION, url: SITE_URL, icons: [SITE_ICON_URL] },
          }),
        ]
      : []),
    coinbaseWallet({ appName: SITE_NAME }),
  ],
  batch: { multicall: true },
  transports: {
    [chain.id]: fallback(RPC_URLS.map((url) => http(url, { batch: true }))),
  },
});

declare module "wagmi" {
  interface Register {
    config: typeof config;
  }
}
