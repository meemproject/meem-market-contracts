import { HardhatEthersHelpers } from '@nomiclabs/hardhat-ethers/types'
import { HardhatUpgrades } from '@openzeppelin/hardhat-upgrades'
import { task, types } from 'hardhat/config'
import { HardhatArguments } from 'hardhat/types'

export async function upgrade(
	args: any,
	options: {
		ethers: HardhatEthersHelpers
		upgrades: HardhatUpgrades
		hardhatArguments?: HardhatArguments
	}
) {
	const { ethers, upgrades } = options
	const [deployer] = await ethers.getSigners()
	console.log('Deploying contracts with the account:', deployer.address)

	console.log('Account balance:', (await deployer.getBalance()).toString())

	const AuctionHouse = await ethers.getContractFactory('AuctionHouse')
	const auctionHouse = await upgrades.upgradeProxy(args.proxy, AuctionHouse)

	await auctionHouse.deployed()

	console.log('Auction house upgraded:', auctionHouse.address)
}

task('upgradeContract', 'Upgrade Auction House')
	.addParam('proxy', 'The proxy address', undefined, types.string, false)
	.setAction(async (args, { ethers, upgrades, hardhatArguments }) => {
		const result = await upgrade(args, { ethers, upgrades, hardhatArguments })
		return result
	})
