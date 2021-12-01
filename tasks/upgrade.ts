import { task, types } from 'hardhat/config'

task('upgradeContract', 'Deploys Meem Gate Token')
	.addParam(
		'contractaddress',
		'The originally deployed contract address',
		undefined,
		types.string,
		false
	)
	.setAction(async (args, { ethers, upgrades }) => {
		const [deployer] = await ethers.getSigners()
		console.log('Deploying contracts with the account:', deployer.address)

		console.log('Account balance:', (await deployer.getBalance()).toString())


		const AuctionHouse = await ethers.getContractFactory('AuctionHouse')
		const auctionHouse = await upgrades.upgradeProxy(args.contractaddress, AuctionHouse)

		await auctionHouse.deployed()

		console.log('Auction house upgraded:', auctionHouse.address)
	})
