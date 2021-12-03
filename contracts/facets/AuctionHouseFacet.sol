// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

import {SafeMathUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol';
import {IERC721Upgradeable, IERC165Upgradeable} from '@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol';
import {IERC20Upgradeable} from '@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol';
import {SafeERC20Upgradeable} from '@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol';
import {IAuctionHouse} from '../interfaces/IAuctionHouse.sol';
import '@solidstate/contracts/utils/ReentrancyGuard.sol';
import {Constants} from '../libraries/Constants.sol';
import {AuctionAlreadyActive, AuctionNotFound} from '../libraries/Errors.sol';
import {LibAppStorage} from '../storage/LibAppStorage.sol';

interface IWETH {
	function deposit() external payable;

	function withdraw(uint256 wad) external;

	function transfer(address to, uint256 value) external returns (bool);
}

/**
 * @title An open auction house, enabling collectors and curators to run their own auctions
 */
contract AuctionHouseFacet is IAuctionHouse, ReentrancyGuard {
	using SafeMathUpgradeable for uint256;
	using SafeERC20Upgradeable for IERC20Upgradeable;

	// // The minimum amount of time left in an auction after a new bid is created
	// uint256 public timeBuffer;

	// // The minimum percentage difference between the last bid amount and the current bid.
	// uint8 public minBidIncrementPercentage;

	// // The address of the meem contract
	// address public meemContract;

	// // / The address of the WETH contract, so that any ETH transferred can be handled as an ERC-20
	// address public wethAddress;

	// // A mapping of all of the auctions currently running.
	// mapping(uint256 => IAuctionHouse.Auction) public auctions;

	// bytes4 constant interfaceId = 0x80ac58cd; // 721 interface id

	// CountersUpgradeable.Counter private _auctionIdTracker;

	/**
	 * @notice Require that the specified auction exists
	 */
	modifier auctionExists(address tokenContract, uint256 tokenId) {
		if (!_exists(tokenContract, tokenId)) {
			revert AuctionNotFound();
		}
		_;
	}

	/*
	 * Constructor
	 */
	// function initialize(address _meemContract, address _weth) public {
	// 	require(
	// 		IERC165Upgradeable(_meemContract).supportsInterface(interfaceId),
	// 		"Doesn't support NFT interface"
	// 	);

	// 	__UUPSUpgradeable_init();

	// 	meemContract = _meemContract;
	// 	wethAddress = _weth;
	// 	timeBuffer = 15 * 60; // extend 15 minutes after every bid made in last 15 minutes
	// 	minBidIncrementPercentage = 5; // 5%
	// }

	function echo() public pure returns (string memory) {
		return 'Hello Auction House!';
	}

	/**
	 * @notice Create an auction.
	 * @dev Store the auction details in the auctions mapping and emit an AuctionCreated event.
	 * If there is no curator, or if the curator is the auction creator, automatically approve the auction.
	 */
	function createAuction(
		address tokenContract,
		uint256 tokenId,
		uint256 duration,
		uint256 reservePrice,
		address payable curator,
		uint8 curatorFeePercentage,
		address auctionCurrency
	) external override nonReentrant {
		require(
			IERC165Upgradeable(tokenContract).supportsInterface(
				Constants.erc721InterfaceId
			),
			'tokenContract does not support ERC721 interface'
		);
		require(
			curatorFeePercentage < 100,
			'curatorFeePercentage must be less than 100'
		);
		address tokenOwner = IERC721Upgradeable(tokenContract).ownerOf(tokenId);
		require(
			msg.sender ==
				IERC721Upgradeable(tokenContract).getApproved(tokenId) ||
				msg.sender == tokenOwner,
			'Caller must be approved or owner for token id'
		);

		LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
		// uint256 auctionId = _auctionIdTracker.current();

		if (s.auctions[tokenContract][tokenId].isActive) {
			revert AuctionAlreadyActive();
		}

		s.auctions[tokenContract][tokenId] = Auction({
			isActive: true,
			tokenId: tokenId,
			tokenContract: tokenContract,
			approved: false,
			amount: 0,
			duration: duration,
			firstBidTime: 0,
			reservePrice: reservePrice,
			curatorFeePercentage: curatorFeePercentage,
			tokenOwner: tokenOwner,
			bidder: payable(address(0)),
			curator: curator,
			auctionCurrency: auctionCurrency,
			timeBuffer: s.timeBuffer,
			minBidIncrementPercentage: s.minBidIncrementPercentage
		});

		IERC721Upgradeable(tokenContract).transferFrom(
			tokenOwner,
			address(this),
			tokenId
		);

		// _auctionIdTracker.increment();

		emit AuctionCreated(
			tokenContract,
			tokenId,
			duration,
			reservePrice,
			tokenOwner,
			curator,
			curatorFeePercentage,
			auctionCurrency
		);

		if (
			s.auctions[tokenContract][tokenId].curator == address(0) ||
			curator == tokenOwner
		) {
			_approveAuction(tokenContract, tokenId, true);
		}
	}

	/**
	 * @notice Approve an auction, opening up the auction for bids.
	 * @dev Only callable by the curator. Cannot be called if the auction has already started.
	 */
	function setAuctionApproval(
		address tokenContract,
		uint256 tokenId,
		bool approved
	) external override auctionExists(tokenContract, tokenId) {
		LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();

		require(
			msg.sender == s.auctions[tokenContract][tokenId].curator,
			'Must be auction curator'
		);
		require(
			s.auctions[tokenContract][tokenId].firstBidTime == 0,
			'Auction has already started'
		);
		_approveAuction(tokenContract, tokenId, approved);
	}

	function setAuctionReservePrice(
		address tokenContract,
		uint256 tokenId,
		uint256 reservePrice
	) external override auctionExists(tokenContract, tokenId) {
		LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();

		require(
			msg.sender == s.auctions[tokenContract][tokenId].curator ||
				msg.sender == s.auctions[tokenContract][tokenId].tokenOwner,
			'Must be auction curator or token owner'
		);
		require(
			s.auctions[tokenContract][tokenId].firstBidTime == 0,
			'Auction has already started'
		);

		s.auctions[tokenContract][tokenId].reservePrice = reservePrice;

		emit AuctionReservePriceUpdated(tokenContract, tokenId, reservePrice);
	}

	/**
	 * @notice Create a bid on a token, with a given amount.
	 * @dev If provided a valid bid, transfers the provided amount to this contract.
	 * If the auction is run in native ETH, the ETH is wrapped so it can be identically to other
	 * auction currencies in this contract.
	 */
	function createBid(
		address tokenContract,
		uint256 tokenId,
		uint256 amount
	)
		external
		payable
		override
		auctionExists(tokenContract, tokenId)
		nonReentrant
	{
		LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();

		address payable lastBidder = s.auctions[tokenContract][tokenId].bidder;
		require(
			s.auctions[tokenContract][tokenId].approved,
			'Auction must be approved by curator'
		);
		require(
			s.auctions[tokenContract][tokenId].firstBidTime == 0 ||
				block.timestamp <
				s.auctions[tokenContract][tokenId].firstBidTime.add(
					s.auctions[tokenContract][tokenId].duration
				),
			'Auction expired'
		);
		require(
			amount >= s.auctions[tokenContract][tokenId].reservePrice,
			'Must send at least reservePrice'
		);
		require(
			amount >=
				s.auctions[tokenContract][tokenId].amount.add(
					s
						.auctions[tokenContract][tokenId]
						.amount
						.mul(s.minBidIncrementPercentage)
						.div(100)
				),
			'Must send more than last bid by minBidIncrementPercentage amount'
		);

		// If this is the first valid bid, we should set the starting time now.
		// If it's not, then we should refund the last bidder
		if (s.auctions[tokenContract][tokenId].firstBidTime == 0) {
			s.auctions[tokenContract][tokenId].firstBidTime = block.timestamp;
		} else if (lastBidder != address(0)) {
			_handleOutgoingBid(
				lastBidder,
				s.auctions[tokenContract][tokenId].amount,
				s.auctions[tokenContract][tokenId].auctionCurrency
			);
		}

		_handleIncomingBid(
			amount,
			s.auctions[tokenContract][tokenId].auctionCurrency
		);

		s.auctions[tokenContract][tokenId].amount = amount;
		s.auctions[tokenContract][tokenId].bidder = payable(msg.sender);

		// Finalize bid in separate function to prevent stack limit error
		_finalizeBid(tokenContract, tokenId, amount, lastBidder == address(0));
	}

	/**
	 * @notice End an auction, finalizing the bid on Zora if applicable and paying out the respective parties.
	 * @dev If for some reason the auction cannot be finalized (invalid token recipient, for example),
	 * The auction is reset and the NFT is transferred back to the auction creator.
	 */
	function endAuction(address tokenContract, uint256 tokenId)
		external
		override
		auctionExists(tokenContract, tokenId)
		nonReentrant
	{
		LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();

		require(
			uint256(s.auctions[tokenContract][tokenId].firstBidTime) != 0,
			"Auction hasn't begun"
		);
		require(
			block.timestamp >=
				s.auctions[tokenContract][tokenId].firstBidTime.add(
					s.auctions[tokenContract][tokenId].duration
				),
			"Auction hasn't completed"
		);

		address currency = s.auctions[tokenContract][tokenId].auctionCurrency ==
			address(0)
			? s.wethContract
			: s.auctions[tokenContract][tokenId].auctionCurrency;
		uint256 curatorFee = 0;

		uint256 tokenOwnerProfit = s.auctions[tokenContract][tokenId].amount;

		// Transfer the token to the winner and pay out the participants below
		try
			IERC721Upgradeable(s.auctions[tokenContract][tokenId].tokenContract)
				.safeTransferFrom(
					address(this),
					s.auctions[tokenContract][tokenId].bidder,
					s.auctions[tokenContract][tokenId].tokenId
				)
		{} catch {
			_handleOutgoingBid(
				s.auctions[tokenContract][tokenId].bidder,
				s.auctions[tokenContract][tokenId].amount,
				s.auctions[tokenContract][tokenId].auctionCurrency
			);
			_cancelAuction(tokenContract, tokenId);
			return;
		}

		if (s.auctions[tokenContract][tokenId].curator != address(0)) {
			curatorFee = tokenOwnerProfit
				.mul(s.auctions[tokenContract][tokenId].curatorFeePercentage)
				.div(100);
			tokenOwnerProfit = tokenOwnerProfit.sub(curatorFee);
			_handleOutgoingBid(
				s.auctions[tokenContract][tokenId].curator,
				curatorFee,
				s.auctions[tokenContract][tokenId].auctionCurrency
			);
		}
		_handleOutgoingBid(
			s.auctions[tokenContract][tokenId].tokenOwner,
			tokenOwnerProfit,
			s.auctions[tokenContract][tokenId].auctionCurrency
		);

		emit AuctionEnded(
			tokenContract,
			tokenId,
			s.auctions[tokenContract][tokenId].tokenOwner,
			s.auctions[tokenContract][tokenId].curator,
			s.auctions[tokenContract][tokenId].bidder,
			tokenOwnerProfit,
			curatorFee,
			currency
		);
		// delete s.auctions[tokenContract][tokenId];
		s.auctions[tokenContract][tokenId].isActive = false;
	}

	/**
	 * @notice Cancel an auction.
	 * @dev Transfers the NFT back to the auction creator and emits an AuctionCanceled event
	 */
	function cancelAuction(address tokenContract, uint256 tokenId)
		external
		override
		nonReentrant
		auctionExists(tokenContract, tokenId)
	{
		LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
		require(
			s.auctions[tokenContract][tokenId].tokenOwner == msg.sender ||
				s.auctions[tokenContract][tokenId].curator == msg.sender,
			'Can only be called by auction creator or curator'
		);
		require(
			uint256(s.auctions[tokenContract][tokenId].firstBidTime) == 0,
			"Can't cancel an auction once it's begun"
		);
		_cancelAuction(tokenContract, tokenId);
	}

	function _finalizeBid(
		address tokenContract,
		uint256 tokenId,
		uint256 amount,
		bool isFirstBid
	) internal {
		LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();

		bool extended = false;
		// at this point we know that the timestamp is less than start + duration (since the auction would be over, otherwise)
		// we want to know by how much the timestamp is less than start + duration
		// if the difference is less than the timeBuffer, increase the duration by the timeBuffer
		if (
			s
				.auctions[tokenContract][tokenId]
				.firstBidTime
				.add(s.auctions[tokenContract][tokenId].duration)
				.sub(block.timestamp) < s.timeBuffer
		) {
			// Playing code golf for gas optimization:
			// uint256 expectedEnd = s.auctions[tokenContract][tokenId].firstBidTime.add(s.auctions[tokenContract][tokenId].duration);
			// uint256 timeRemaining = expectedEnd.sub(block.timestamp);
			// uint256 timeToAdd = timeBuffer.sub(timeRemaining);
			// uint256 newDuration = s.auctions[tokenContract][tokenId].duration.add(timeToAdd);
			uint256 oldDuration = s.auctions[tokenContract][tokenId].duration;
			s.auctions[tokenContract][tokenId].duration = oldDuration.add(
				s.timeBuffer.sub(
					s
						.auctions[tokenContract][tokenId]
						.firstBidTime
						.add(oldDuration)
						.sub(block.timestamp)
				)
			);
			extended = true;
		}

		emit AuctionBid(
			s.auctions[tokenContract][tokenId].tokenContract,
			s.auctions[tokenContract][tokenId].tokenId,
			msg.sender,
			amount,
			isFirstBid,
			extended
		);

		if (extended) {
			emit AuctionDurationExtended(
				s.auctions[tokenContract][tokenId].tokenContract,
				s.auctions[tokenContract][tokenId].tokenId,
				s.auctions[tokenContract][tokenId].duration
			);
		}
	}

	/**
	 * @dev Given an amount and a currency, transfer the currency to this contract.
	 * If the currency is ETH (0x0), attempt to wrap the amount as WETH
	 */
	function _handleIncomingBid(uint256 amount, address currency) internal {
		LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();

		// If this is an ETH bid, ensure they sent enough and convert it to WETH under the hood
		if (currency == address(0)) {
			require(
				msg.value == amount,
				'Sent ETH Value does not match specified bid amount'
			);
			IWETH(s.wethContract).deposit{value: amount}();
		} else {
			// We must check the balance that was actually transferred to the auction,
			// as some tokens impose a transfer fee and would not actually transfer the
			// full amount to the market, resulting in potentally locked funds
			IERC20Upgradeable token = IERC20Upgradeable(currency);
			uint256 beforeBalance = token.balanceOf(address(this));
			token.safeTransferFrom(msg.sender, address(this), amount);
			uint256 afterBalance = token.balanceOf(address(this));
			require(
				beforeBalance.add(amount) == afterBalance,
				'Token transfer call did not transfer expected amount'
			);
		}
	}

	function _handleOutgoingBid(
		address to,
		uint256 amount,
		address currency
	) internal {
		LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();

		// If the auction is in ETH, unwrap it from its underlying WETH and try to send it to the recipient.
		if (currency == address(0)) {
			IWETH(s.wethContract).withdraw(amount);

			// If the ETH transfer fails (sigh), rewrap the ETH and try send it as WETH.
			if (!_safeTransferETH(to, amount)) {
				IWETH(s.wethContract).deposit{value: amount}();
				IERC20Upgradeable(s.wethContract).safeTransfer(to, amount);
			}
		} else {
			IERC20Upgradeable(currency).safeTransfer(to, amount);
		}
	}

	function _safeTransferETH(address to, uint256 value)
		internal
		returns (bool)
	{
		(bool success, ) = to.call{value: value}(new bytes(0));
		return success;
	}

	function _cancelAuction(address tokenContract, uint256 tokenId) internal {
		LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();

		address tokenOwner = s.auctions[tokenContract][tokenId].tokenOwner;
		IERC721Upgradeable(s.auctions[tokenContract][tokenId].tokenContract)
			.safeTransferFrom(
				address(this),
				tokenOwner,
				s.auctions[tokenContract][tokenId].tokenId
			);

		emit AuctionCanceled(
			s.auctions[tokenContract][tokenId].tokenContract,
			s.auctions[tokenContract][tokenId].tokenId,
			tokenOwner
		);
		// delete s.auctions[tokenContract][tokenId];
		s.auctions[tokenContract][tokenId].isActive = false;
	}

	function _approveAuction(
		address tokenContract,
		uint256 tokenId,
		bool approved
	) internal {
		LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();

		s.auctions[tokenContract][tokenId].approved = approved;
		emit AuctionApprovalUpdated(
			s.auctions[tokenContract][tokenId].tokenContract,
			s.auctions[tokenContract][tokenId].tokenId,
			approved
		);
	}

	function _exists(address tokenContract, uint256 tokenId)
		internal
		view
		returns (bool)
	{
		LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
		return s.auctions[tokenContract][tokenId].isActive;
	}

	// function _handleZoraAuctionSettlement(uint256 auctionId)
	// 	internal
	// 	returns (bool, uint256)
	// {
	// 	address currency = auctions[auctionId].auctionCurrency == address(0)
	// 		? wethAddress
	// 		: auctions[auctionId].auctionCurrency;

	// 	IMarket.Bid memory bid = IMarket.Bid({
	// 		amount: auctions[auctionId].amount,
	// 		currency: currency,
	// 		bidder: address(this),
	// 		recipient: auctions[auctionId].bidder,
	// 		sellOnShare: Decimal.D256(0)
	// 	});

	// 	IERC20Upgradeable(currency).approve(
	// 		IMediaExtended(zora).marketContract(),
	// 		bid.amount
	// 	);
	// 	IMedia(zora).setBid(auctions[auctionId].tokenId, bid);
	// 	uint256 beforeBalance = IERC20Upgradeable(currency).balanceOf(
	// 		address(this)
	// 	);
	// 	try IMedia(zora).acceptBid(auctions[auctionId].tokenId, bid) {} catch {
	// 		// If the underlying NFT transfer here fails, we should cancel the auction and refund the winner
	// 		IMediaExtended(zora).removeBid(auctions[auctionId].tokenId);
	// 		return (false, 0);
	// 	}
	// 	uint256 afterBalance = IERC20Upgradeable(currency).balanceOf(
	// 		address(this)
	// 	);

	// 	// We have to calculate the amount to send to the token owner here in case there was a
	// 	// sell-on share on the token
	// 	return (true, afterBalance.sub(beforeBalance));
	// }

	// TODO: consider reverting if the message sender is not WETH
	receive() external payable {}

	fallback() external payable {}
}
