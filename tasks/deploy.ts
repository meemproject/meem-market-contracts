import path from 'path'
import { HardhatEthersHelpers } from '@nomiclabs/hardhat-ethers/types'
import { ethers as Ethers } from 'ethers'
import fs from 'fs-extra'
import { task } from 'hardhat/config'
import { HardhatArguments } from 'hardhat/types'
import { HardhatUpgrades } from '@openzeppelin/hardhat-upgrades'


export async function deploy(options: {
	ethers: HardhatEthersHelpers
	upgrades: HardhatUpgrades
	hardhatArguments?: HardhatArguments
}) {
	const { ethers, upgrades, hardhatArguments } = options
	const deployedContracts: Record<string, string> = {}
	const network = await ethers.provider.getNetwork()
	const { chainId } = network

	const accounts = await ethers.getSigners()
	const contractOwner = accounts[0]
	console.log('Deploying contracts with the account:', contractOwner.address)

	console.log('Account balance:', (await contractOwner.getBalance()).toString())

	let contractAddress = '0x5FbDB2315678afecb367f032d93F642f64180aa3'
	let wethAddress = '0xc778417e063141139fce010982780140aa0cd5ab'

	switch (hardhatArguments?.network) {
		case 'matic':
		case 'polygon':
			contractAddress = '0xfEED3502Ec230122ac5c7C78C21E9C644e1067eD'
			wethAddress = '0x7ceb23fd6bc0add59e62ac25578270cff1b9f619'
			break

		case 'rinkeby':
			contractAddress = '0x87e5882fa0ea7e391b7e31E8b23a8a38F35C84Ac'
			wethAddress = '0xc778417e063141139fce010982780140aa0cd5ab'
			break

		case 'mainnet':
			contractAddress = ''
			wethAddress = ''
			break

		case 'local':
		default:
			contractAddress = '0x5FbDB2315678afecb367f032d93F642f64180aa3'
			wethAddress = '0xc778417e063141139fce010982780140aa0cd5ab'
			break
	}

	const AuctionHouse = await ethers.getContractFactory('AuctionHouse')
	// const auctionHouse = await AuctionHouse.deploy(contractAddress, wethAddress)
	console.log([contractAddress, wethAddress])
	const auctionHouse = await upgrades.deployProxy(
		AuctionHouse,
		[contractAddress, wethAddress],
		{
			kind: 'uups'
		}
	)

	await auctionHouse.deployed()
	deployedContracts.AuctionHouse = auctionHouse.address

	console.log({
		deployedContracts
	})

	return deployedContracts
}

task('deploy', 'Deploys Auction House').setAction(
	async (args, { ethers, upgrades, hardhatArguments }) => {
		const result = await deploy({ ethers, upgrades, hardhatArguments })
		return result
	}
)
