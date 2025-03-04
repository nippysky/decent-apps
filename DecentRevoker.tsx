"use client";

import { useState, useEffect } from "react";
import { useAccount } from "wagmi";
import { ethers } from "ethers";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import Header from "../header";
import { MoveLeft } from "lucide-react";
import { useRouter } from "next/navigation";
import Footer from "../footer";
import Link from "next/link";
import { toast } from "sonner"; // Import toast for feedback

// ERC-20 ABI with decimals()
const ERC20_ABI = [
  "event Approval(address indexed owner, address indexed spender, uint256 value)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
];

interface TokenApproval {
  address: string;
  symbol: string;
  allowance: string;
  spender: string;
}

export default function DecentRevokeComponent() {
  const router = useRouter();
  const { address, isConnected } = useAccount();

  const [approvals, setApprovals] = useState<TokenApproval[]>([]);
  const [loading, setLoading] = useState<boolean>(false);
  const [revokingToken, setRevokingToken] = useState<string | null>(null); // Tracks token being revoked

  useEffect(() => {
    if (!isConnected) {
      router.push("/apps");
    }
  }, [isConnected, router]);

  useEffect(() => {
    if (isConnected && address) {
      fetchApprovals();
    }
  }, [isConnected, address]);

  async function fetchApprovals() {
    if (!window.ethereum || !address) return;
    const provider = new ethers.BrowserProvider(window.ethereum);
    setLoading(true);
    try {
      const logs = await provider.getLogs({
        fromBlock: "earliest",
        toBlock: "latest",
        topics: [
          ethers.id("Approval(address,address,uint256)"),
          ethers.zeroPadValue(address, 32),
        ],
      });

      const uniqueContracts = new Set<string>();
      const tokens: TokenApproval[] = (
        await Promise.all(
          logs.map(async (log) => {
            const contractAddress = log.address;
            if (uniqueContracts.has(contractAddress)) return null;
            uniqueContracts.add(contractAddress);

            const contract = new ethers.Contract(
              contractAddress,
              ERC20_ABI,
              provider
            );
            try {
              const symbol: string = await contract.symbol();
              const decimals: number = await contract.decimals();
              const rawSpender = log.topics[2];
              const spender = ethers.getAddress("0x" + rawSpender.slice(26));
              const allowanceBigInt = await contract.allowance(
                address,
                spender
              );

              if (allowanceBigInt > BigInt(0)) {
                // Detect max uint256 value for unlimited approval
                const MAX_UINT256 = BigInt(
                  "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
                );
                const formattedAllowance = ethers.formatUnits(
                  allowanceBigInt,
                  decimals
                );

                const truncatedAllowance =
                  allowanceBigInt === MAX_UINT256
                    ? "Has Unlimited access. You should revoke, unless sure."
                    : Number(formattedAllowance).toFixed(5);

                return {
                  address: contractAddress,
                  symbol,
                  allowance: truncatedAllowance,
                  spender,
                };
              }
            } catch (err) {
              console.error("Skipping contract:", contractAddress, err);
            }
            return null;
          })
        )
      ).filter((token): token is TokenApproval => token !== null);

      setApprovals(tokens);
      toast.success("Token approvals fetched successfully!"); // Notify success
    } catch (error) {
      console.error("Error fetching approvals:", error);
      toast.error("Failed to fetch token approvals."); // Notify failure
    }
    setLoading(false);
  }

  async function revokeApproval(token: TokenApproval) {
    if (!window.ethereum || !address) return;
    const provider = new ethers.BrowserProvider(window.ethereum);
    const signer = await provider.getSigner(address);
    if (!signer) return;

    setRevokingToken(token.address); // Set token as revoking

    try {
      const contract = new ethers.Contract(token.address, ERC20_ABI, signer);
      const tx = await contract.approve(token.spender, 0);
      await tx.wait();

      toast.success(`${token.symbol} approval revoked successfully!`); // Success feedback
      fetchApprovals(); // Refresh approvals after revoke
    } catch (error) {
      console.error("Error revoking approval:", error);
      toast.error(`Failed to revoke approval for ${token.symbol}`); // Failure feedback
    }

    setRevokingToken(null); // Reset revoking state
  }

  return (
    <section className="flex-1">
      <Header />

      {/* Back button */}
      <div className="w-full pt-5 lg:px-20 md:px-10 px-5 bg-white dark:bg-black">
        <button
          className="text-decentDarkGreen dark:text-decentGreen flex gap-2 items-center"
          onClick={() => router.back()}
        >
          <MoveLeft />
          Go back
        </button>
      </div>

      <div className="w-full flex flex-col md:flex-row justify-between md:items-center gap-5 md:gap-10 py-10 bg-white dark:bg-black lg:px-20 md:px-10 px-5">
        <div className="w-full md:w-[50%] lg:w-[60%]">
          <h1 className="font-semibold text-2xl lg:text-3xl">Decent Revoker</h1>
          <p className="text-[0.85rem] mt-2">
            A secure and effortless way to track and revoke token approvals,
            giving you full control over your assets.
          </p>
        </div>
        <div className="flex-1 flex md:justify-end justify-start">
          <ConnectButton />
        </div>
      </div>

      <section className="flex-1 w-full py-10 lg:py-20 flex flex-col bg-white dark:bg-black lg:px-20 md:px-10 px-5">
        <h1 className="text-2xl font-bold mt-4">Token Approvals</h1>
        {loading ? (
          <p>Loading approvals...</p>
        ) : approvals.length > 0 ? (
          approvals.map((token) => (
            <Card key={token.address} className="mt-4 rounded-none p-5">
              <CardContent>
                <p className="text-decentGreen font-bold tracking-wide lg:text-xl text-lg">
                  {token.symbol}
                </p>
                <p className="my-3">
                  <strong>Token CA:</strong>{" "}
                  <Link
                    href={`https://blockexplorer.electroneum.com/address/${token.address}`}
                    target="_blank"
                    className="text-decentGreen hover:underline"
                  >
                    {token.address}
                  </Link>
                </p>
                <p className="my-3">
                  <strong>Spender:</strong>{" "}
                  <Link
                    href={`https://blockexplorer.electroneum.com/address/${token.spender}`}
                    target="_blank"
                    className="text-decentGreen hover:underline"
                  >
                    {token.spender}
                  </Link>
                </p>
                <p className="my-3">
                  <strong>Allowance:</strong> {token.allowance}
                </p>
                <Button
                  className="rounded-none mt-5 bg-red-600"
                  onClick={() => revokeApproval(token)}
                  variant="destructive"
                  disabled={revokingToken === token.address} // Disable while revoking
                >
                  {revokingToken === token.address
                    ? "Revoking..."
                    : "Revoke Approval"}
                </Button>
              </CardContent>
            </Card>
          ))
        ) : (
          <p className="mt-4 text-gray-500">
            No token approvals found. You're all set! ✅
          </p>
        )}
      </section>

      <Footer />
    </section>
  );
}
